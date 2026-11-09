//
//  CompanionChat.swift
//  Curfs
//
//  Curfs AI: un amico che spiega cosa si sta guardando, con il modello di
//  Apple Intelligence sul dispositivo (FoundationModels: gratis, offline, le
//  domande non escono dal telefono/Mac). Il modello è piccolo (contesto di
//  ~8k token) e con gli strumenti (tool calling) non è affidabile: gli si dà
//  tutto già pronto nelle istruzioni, in inglese (rende meglio) con la
//  risposta nella lingua dell'app:
//  - serie: cast, trama degli episodi già visti, presentazione di questo;
//  - film: la trama di Wikipedia tagliata a dove si è arrivati;
//  - per entrambi: i dialoghi degli ultimi minuti dai sottotitoli del file.
//  Niente spoiler di regola: nel contesto c'è solo quello che si è già visto,
//  e il tasto "Spoiler" (scelta esplicita di chi guarda) aggiunge il resto.
//  La chat non si salva: vive finché è aperta la schermata/il player.
//

import Foundation
@preconcurrency import AVFoundation
import FoundationModels
import NaturalLanguage
import Observation

/// Cosa si sta guardando e a che punto: un'istantanea del `MediaItem`, così la
/// chat non dipende dal modello SwiftData.
struct CompanionTarget: Identifiable {
    let id: UUID
    let kind: MediaKind
    let title: String
    let showName: String?
    let season: Int?
    let episode: Int?
    let duration: Double
    let position: Double
    let playbackURL: URL
    let isRemote: Bool

    init(item: MediaItem, position: Double? = nil) {
        id = item.id
        kind = item.kind
        title = item.title
        showName = item.showName
        season = item.seasonNumber
        episode = item.episodeNumber
        duration = item.duration
        self.position = position ?? (item.isFinished ? item.duration : item.playbackPosition)
        playbackURL = item.playbackURL
        isRemote = item.isRemote
    }

    var displayTitle: String { showName ?? title }

    var detail: String? {
        guard kind == .episode else { return nil }
        if let season, let episode { return String(format: "S%02dE%02d", season, episode) + " · " + title }
        return title
    }

    /// Asset per leggere i sottotitoli fuori dal player (dalla libreria):
    /// con gli header di autenticazione del server se è in streaming.
    func makeAsset() -> AVURLAsset {
        let headers = isRemote ? RemoteSourceStore.current.authHeaders : [:]
        let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        return AVURLAsset(url: playbackURL, options: options)
    }
}

@MainActor
@Observable
final class CompanionChat {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var isError = false
    }

    enum Availability: Equatable {
        case available
        /// Apple Intelligence spenta nelle Impostazioni.
        case notEnabled
        /// Modello ancora da scaricare.
        case notReady
        /// Dispositivo non compatibile.
        case unsupported
    }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .notReady
        default: return .unsupported
        }
    }

    /// I tasti di Curfs AI si mostrano solo dove il modello può esserci.
    /// Calcolato una volta: se cambiasse a metà, i tasti comparirebbero e
    /// sparirebbero dalle barre in alto (vedi LibraryHomeView).
    static let isOffered: Bool = availability != .unsupported

    let target: CompanionTarget
    private(set) var messages: [Message] = []
    private(set) var isResponding = false
    private(set) var isPreparing = false
    /// Da dove vengono trama e cast (link alla pagina della serie/episodio/film).
    private(set) var source: (name: String, url: URL)?
    private(set) var position: Double
    /// Trovati trama/cast online, letti dei dialoghi: per dire a chi guarda su cosa si basa.
    private(set) var hasInfo = false
    private(set) var hasDialogue = false
    var spoilersAllowed = false {
        didSet { if spoilersAllowed != oldValue { session = nil } }
    }

    /// Nel player: dove si è adesso (la chat resta aperta mentre il video va).
    @ObservationIgnored var currentPosition: (() -> Double)?
    @ObservationIgnored private let asset: AVAsset?
    @ObservationIgnored private let subtitleTrack: Int?
    @ObservationIgnored private var show: ShowInfo?
    /// Trame da Wikipedia degli ultimi episodi visti, per "S<s>E<e>".
    @ObservationIgnored private var episodePlots: [String: String] = [:]
    /// Pagina Wikipedia usata (per citarla).
    private(set) var wikipediaSource: URL?
    @ObservationIgnored private var movie: MovieInfo?
    @ObservationIgnored private var dialogueTracks: [Int: [DialogueReader.Line]] = [:]
    @ObservationIgnored private var dialoguePosition: Double = -1
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    /// Lingua dell'ultima domanda riconosciuta: per le domande troppo corte per dirlo.
    @ObservationIgnored private var replyLanguage: String?

    init(target: CompanionTarget, asset: AVAsset? = nil, subtitleTrack: Int? = nil) {
        self.target = target
        self.position = target.position
        self.asset = asset
        self.subtitleTrack = subtitleTrack
    }

    /// Scarica trama/cast e legge i dialoghi; si può chiamare più volte.
    func prepare() {
        guard preparation == nil else { return }
        isPreparing = true
        preparation = Task {
            async let info: Void = loadInfo()
            async let lines: Void = refreshDialogue()
            _ = await (info, lines)
            isPreparing = false
            if Self.availability == .available { makeSession().prewarm() }
        }
    }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        messages.append(Message(role: .user, text: question))
        isResponding = true
        Task {
            await preparation?.value
            if let now = currentPosition?(), abs(now - position) > 20 {
                position = now
                await refreshDialogue()
                session = nil
            }
            // Lingua cambiata: i dialoghi vanno presi dalla traccia in quella
            // lingua, quindi la sessione riparte.
            if let language = Self.language(of: question), language != replyLanguage {
                if replyLanguage != nil || language != CompanionLanguage.englishName { session = nil }
                replyLanguage = language
            }
            await answer(question, retryOnOverflow: true)
            isResponding = false
        }
    }

    // MARK: - Risposta

    private func answer(_ question: String, retryOnOverflow: Bool) async {
        guard Self.availability == .available else {
            messages.append(Message(role: .assistant, text: Self.unavailableText, isError: true))
            return
        }
        let current = session ?? makeSession()
        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        do {
            for try await partial in current.streamResponse(to: prompt(for: question)) {
                update(reply.id) { $0.text = partial.content }
            }
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // Chat lunga: si riparte con un contesto nuovo e meno storia.
            messages.removeAll { $0.id == reply.id }
            session = nil
            if retryOnOverflow {
                await answer(question, retryOnOverflow: false)
            } else {
                messages.append(Message(role: .assistant, text: String(localized: "La chat è diventata troppo lunga: chiudila e riaprila per ricominciare."), isError: true))
            }
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            update(reply.id) {
                $0.text = String(localized: "Su questo non posso risponderti.")
                $0.isError = true
            }
        } catch {
            update(reply.id) {
                $0.text = String(localized: "Non sono riuscito a rispondere. Riprova tra poco.")
                $0.isError = true
            }
        }
    }

    /// La lingua va ripetuta a ogni domanda: con le istruzioni in inglese il
    /// modello piccolo rispondeva in inglese anche a domande in italiano, e una
    /// volta partito così la chat lo trascinava (visto su The Walking Dead).
    private func prompt(for question: String) -> String {
        "\(question)\n\n(Answer in \(answerLanguage). Name the characters you talk about.)"
    }

    private var answerLanguage: String { replyLanguage ?? CompanionLanguage.englishName }

    /// Nome inglese della lingua della domanda ("Italian"), se è abbastanza chiara.
    nonisolated static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.italian, .english, .spanish, .french, .german, .portuguese]
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value > 0.5 else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: best.key.rawValue)
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    static var unavailableText: String {
        switch availability {
        case .notEnabled: String(localized: "Per usare Curfs AI attiva Apple Intelligence nelle Impostazioni.")
        case .notReady: String(localized: "Apple Intelligence sta ancora scaricando il modello: riprova tra un po'.")
        default: String(localized: "Curfs AI ha bisogno di Apple Intelligence, che su questo dispositivo non c'è.")
        }
    }

    // MARK: - Contesto

    private func loadInfo() async {
        if target.kind == .episode, let name = target.showName {
            show = await ContentInfoService.shared.show(named: name)
            if let show {
                let episodeURL = show.episode(season: target.season, number: target.episode)?.url
                if let url = episodeURL ?? show.url { source = ("TVmaze", url) }
                await loadEpisodePlots(show)
            }
        } else if target.kind == .movie {
            movie = await ContentInfoService.shared.movie(titled: target.title)
            if let url = movie?.url { source = ("Wikipedia", url) }
        }
        hasInfo = show != nil || movie != nil
    }

    /// Le trame vere degli ultimi 2 episodi visti, in parallelo.
    private func loadEpisodePlots(_ show: ShowInfo) async {
        guard let season = target.season, let number = target.episode else { return }
        let recent = show.episodes(before: season, number).suffix(2)
        let found = await withTaskGroup(of: (String, String, URL?)?.self) { group in
            for episode in recent {
                group.addTask {
                    guard let plot = await ContentInfoService.shared.episodePlot(show: show.name, name: episode.name) else { return nil }
                    return ("S\(episode.season)E\(episode.number)", plot.plot, plot.url)
                }
            }
            var result: [(String, String, URL?)] = []
            for await item in group { if let item { result.append(item) } }
            return result
        }
        for (key, plot, _) in found { episodePlots[key] = plot }
        wikipediaSource = found.compactMap(\.2).first
    }

    private func refreshDialogue() async {
        guard abs(position - dialoguePosition) > 5 else { return }
        dialoguePosition = position
        let asset = self.asset ?? target.makeAsset()
        let remote = target.isRemote ? (url: target.playbackURL, headers: RemoteSourceStore.current.authHeaders) : nil
        dialogueTracks = await DialogueReader.tracks(in: asset, remote: remote, until: position)
        hasDialogue = !dialogueTracks.isEmpty
    }

    private func makeSession() -> LanguageModelSession {
        // Guardrail "permissivi": quelli normali bloccano le risposte su serie
        // violente (Il Trono di Spade); questa modalità è pensata per lavorare
        // su testo dato dall'app (trame, dialoghi), come qui.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let created = LanguageModelSession(model: model, instructions: instructions())
        session = created
        return created
    }

    private var hasFinished: Bool { target.duration > 0 && position >= target.duration - 30 }

    private func instructions() -> String {
        var text = """
        You are Curfs AI, an expert on films and TV series who explains things to a friend while they watch. The viewer asks quick questions about the exact moment they are watching.
        - Always reply in the language the viewer writes in (if unclear, \(CompanionLanguage.englishName)), in a friendly, casual tone. Be brief: 1-3 sentences, unless the viewer asks for a recap. Answer directly, without introductions.
        - Always name the characters: who did what, to whom. Never say "the guy", "someone" or "something" when the CONTEXT tells you who or what it is.
        - What is happening now comes from the DIALOGUE. A name in capitals before a colon ("RICK: Put the gun down") is who speaks; a sound in parentheses ("(GUNSHOT)") is something heard in the scene. Without those, a name at the start of a line ("Shane, wait") is the person being spoken TO, not the speaker; lines starting with "-" are different people. Work out who says and does what from these clues, the characters and the situation.
        - The episode descriptions are vague teasers written by others: never repeat their wording as if it were an event, and never mix them with the current scene.
        - Your own memory of specific episodes is unreliable: rely on the CONTEXT. If the CONTEXT doesn't make something clear (for example who fired), say what you do know and that it isn't clear, instead of guessing. Never invent facts.

        """
        if spoilersAllowed {
            text += "- The viewer has explicitly asked for spoilers: you may reveal what happens later in the story.\n"
        } else {
            text += "- NO SPOILERS: the viewer has seen only what the CONTEXT describes, up to their current point. Never reveal anything that happens later (later in this \(target.kind == .movie ? "film" : "episode or in later episodes"), who dies, twists, endings, identities), even if you know it. If asked, gently refuse and offer a spoiler-free hint instead.\n"
        }
        text += "\nCONTEXT\n" + context()

        let history = earlierChat()
        if !history.isEmpty { text += "\nEARLIER IN THIS CHAT\n" + history }
        return text
    }

    private func context() -> String {
        var lines: [String] = []
        let at = TimeFormatter.format(position)
        let total = target.duration > 0 ? TimeFormatter.format(target.duration) : nil
        let point = hasFinished
            ? "The viewer has finished watching it."
            : "The viewer is at \(at)\(total.map { " of \($0)" } ?? "")."

        if target.kind == .episode {
            let showName = show?.name ?? target.showName ?? target.title
            var now = "TV series: \(showName). Now watching: "
            if let season = target.season, let episode = target.episode {
                now += "Season \(season), Episode \(episode)"
            }
            now += " \"\(show?.episode(season: target.season, number: target.episode)?.name ?? target.title)\". \(point)"
            lines.append(now)
            if let show {
                if !show.summary.isEmpty { lines.append("About the series: " + String(show.summary.prefix(500))) }
                if !show.cast.isEmpty { lines.append("Main characters (actor as character): " + show.cast.prefix(16).joined(separator: "; ") + ".") }
                if let season = target.season, let number = target.episode {
                    let seen = show.episodes(before: season, number).suffix(8)
                    if !seen.isEmpty {
                        lines.append("PREVIOUSLY (episodes already watched):")
                        lines += seen.map { episode in
                            let key = "S\(episode.season)E\(episode.number)"
                            // La trama di Wikipedia è lunga: la parte finale,
                            // quella che porta a dove si è adesso.
                            if let plot = episodePlots[key] {
                                let text = plot.count > 1500 ? "…" + String(plot.suffix(1500)) : plot
                                return "\(key) \"\(episode.name)\" (full plot): \(text)"
                            }
                            return "\(key) \"\(episode.name)\": \(String(episode.summary.prefix(350)))"
                        }
                    }
                    if let current = show.episode(season: season, number: number), !current.summary.isEmpty {
                        lines.append("THIS EPISODE (vague teaser of the whole episode: parts of it may not have happened yet): " + String(current.summary.prefix(500)))
                    }
                    if spoilersAllowed {
                        let later = show.episodes.filter { ($0.season, $0.number) > (season, number) }.prefix(6)
                        if !later.isEmpty {
                            lines.append("LATER EPISODES (the viewer asked for spoilers):")
                            lines += later.map { "S\($0.season)E\($0.number) \"\($0.name)\": \(String($0.summary.prefix(250)))" }
                        }
                    }
                }
            }
        } else {
            lines.append("Film: \(movie?.title ?? target.title). \(point)")
            if let movie {
                if !movie.cast.isEmpty { lines.append("Cast: " + movie.cast) }
                let plot = plotSoFar(movie)
                if !plot.isEmpty {
                    lines.append(spoilersAllowed || hasFinished
                        ? "PLOT (from Wikipedia):"
                        : "STORY SO FAR (approximately what the viewer has already seen, from Wikipedia):")
                    lines.append(plot)
                }
            }
        }

        let dialogue = DialogueReader.merge(dialogueTracks, language: answerLanguage, preferred: subtitleTrack)
        if !dialogue.isEmpty {
            lines.append("DIALOGUE OF THE LAST MINUTES, up to the current point (subtitles, most recent last):")
            var budget = 2600
            var recent: [String] = []
            for line in dialogue.reversed() {
                let entry = "[\(TimeFormatter.format(line.time))] \(line.text)"
                budget -= entry.count + 1
                if budget < 0 { break }
                recent.append(entry)
            }
            lines += recent.reversed()
        }
        return lines.joined(separator: "\n")
    }

    /// La trama del film fino a dove si è (in proporzione al minutaggio, con
    /// un margine per stare indietro), al massimo gli ultimi ~3500 caratteri.
    private func plotSoFar(_ movie: MovieInfo) -> String {
        let full = movie.plot.joined(separator: "\n")
        guard !spoilersAllowed, !hasFinished, target.duration > 0 else { return String(full.suffix(3500)) }
        let fraction = max(0, position / target.duration - 0.06)
        guard fraction > 0 else { return "" }
        let limit = Int(Double(full.count) * fraction)
        var cut = String(full.prefix(limit))
        // Si chiude all'ultima frase intera.
        if let end = cut.lastIndex(where: { $0 == "." || $0 == "\n" }) {
            cut = String(cut[...end])
        }
        return cut.count > 3500 ? "…" + String(cut.suffix(3500)) : cut
    }

    /// Le ultime battute della chat, per non perdere il filo quando la
    /// sessione riparte (spoiler cambiati, si è andati avanti nel video,
    /// contesto pieno).
    private func earlierChat() -> String {
        var done = Array(messages.filter { !$0.isError && !$0.text.isEmpty })
        // La domanda a cui si sta per rispondere arriva come prompt, non qui.
        if done.last?.role == .user { done.removeLast() }
        done = Array(done.suffix(6))
        return done.map { ($0.role == .user ? "Viewer: " : "You: ") + String($0.text.prefix(300)) }
            .joined(separator: "\n")
    }
}
