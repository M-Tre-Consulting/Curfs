//
//  CompanionChatView.swift
//  Curfs
//
//  La chat di Curfs AI: intestazione (cosa si guarda, spoiler sì/no),
//  messaggi, domande pronte per partire subito, campo di testo e la fonte
//  delle informazioni. La stessa view sta nel pannello sopra il video
//  (iPhone), nella colonna accanto al video (Mac) e nella pagina aperta
//  dalla libreria.
//

import SwiftUI

struct CompanionChatView: View {
    let chat: CompanionChat
    var onClose: (() -> Void)?

    @State private var draft = ""
    @State private var confirmSpoilers = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            messagesList
            footer
        }
        .onAppear { chat.prepare() }
        .confirmationDialog("Vuoi gli spoiler?", isPresented: $confirmSpoilers, titleVisibility: .visible) {
            Button("Sì, dimmi tutto") { withAnimation(.bouncy) { chat.spoilersAllowed = true } }
            Button("No, meglio di no", role: .cancel) { }
        } message: {
            Text("Curfs AI potrà raccontarti anche cosa succede dopo il punto in cui sei.")
        }
    }

    // MARK: - Intestazione

    private var header: some View {
        HStack(spacing: 10) {
            CompanionIcon(size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Curfs AI")
                    .font(.headline)
                Text(verbatim: [chat.target.displayTitle, chat.target.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Tasti in vetro nativi: hanno già il "rimbalzo" al tocco di sistema.
            Button {
                if chat.spoilersAllowed {
                    withAnimation(.bouncy) { chat.spoilersAllowed = false }
                } else {
                    confirmSpoilers = true
                }
            } label: {
                Label(chat.spoilersAllowed ? "Spoiler sì" : "Niente spoiler",
                      systemImage: chat.spoilersAllowed ? "eye" : "eye.slash")
                    .font(.caption.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .tint(chat.spoilersAllowed ? Color.orange.opacity(0.45) : nil)
            .help("Spoiler")

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Chiudi")
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Messaggi

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        welcome
                    }
                    ForEach(chat.messages) { message in
                        MessageBubble(message: message, isTyping: chat.isResponding && message.text.isEmpty)
                            .id(message.id)
                    }
                }
                .padding(14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.last?.text) {
                guard let last = chat.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            if CompanionChat.availability != .available {
                Label(CompanionChat.unavailableText, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                Text(chat.target.kind == .movie
                     ? "Ciao! Chiedimi quello che vuoi su questo punto del film: chi è un personaggio, cosa ti sei perso, cosa vuol dire una scena. Niente spoiler, promesso."
                     : "Ciao! Chiedimi quello che vuoi su questo punto dell'episodio: chi è un personaggio, cosa ti sei perso, cosa vuol dire una scena. Niente spoiler, promesso.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if chat.isPreparing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Mi informo su cosa stai guardando…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            chat.send(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestions: [String] {
        var list = [
            String(localized: "Cosa mi sono perso negli ultimi minuti?"),
            String(localized: "Chi sono i personaggi in questa scena?"),
        ]
        if chat.target.kind == .episode {
            list.append(String(localized: "Ricordami cosa è successo negli episodi prima"))
        } else {
            list.append(String(localized: "Riassumimi il film fin qui"))
        }
        return list
    }

    // MARK: - Fondo

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                // Va a capo e cresce fino a 6 righe (poi scorre), come nelle
                // app di messaggi: su una riga sola il testo già scritto
                // spariva a sinistra. Su iPhone Invio va a capo, si manda con
                // la freccia; su Mac Invio manda.
                TextField("Chiedi qualcosa…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    #if os(macOS)
                    .onSubmit(send)
                    #endif
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.1))
                    )

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Color.accentColor)
                .disabled(!canSend)
                .padding(.bottom, 2)
                .accessibilityLabel("Invia")
            }

            sourceLine
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var sourceLine: some View {
        if !chat.isPreparing {
            HStack(spacing: 4) {
                if let source = chat.source {
                    Text("Trama e cast da")
                    Link(destination: source.url) {
                        Text(verbatim: "\(source.name) ↗").underline()
                    }
                    if let wikipedia = chat.wikipediaSource {
                        Text(verbatim: "+")
                        Link(destination: wikipedia) {
                            Text(verbatim: "Wikipedia ↗").underline()
                        }
                    }
                    Text(verbatim: "(CC BY-SA)")
                } else if !chat.hasInfo {
                    Text("Nessuna scheda trovata online: rispondo con quello che so.")
                }
                if chat.hasDialogue {
                    Text(verbatim: "·")
                    Text("dialoghi dai sottotitoli")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && !chat.isResponding
            && CompanionChat.availability == .available
    }

    private func send() {
        guard canSend else { return }
        chat.send(draft)
        draft = ""
    }
}

private struct MessageBubble: View {
    let message: CompanionChat.Message
    let isTyping: Bool

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Group {
                if isTyping {
                    TypingDots()
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                        .foregroundStyle(message.isError ? Color.orange : Color.primary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(message.role == .user ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.09))
            )
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(index == step ? 1 : 0.35)
                }
            }
            .foregroundStyle(.secondary)
            .frame(height: 18)
        }
    }
}

/// L'icona di Curfs AI: scintille su un cerchio sfumato nei colori dell'app.
struct CompanionIcon: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(LinearGradient(
                    colors: [Color.accentColor, Color(red: 0.85, green: 0.35, blue: 0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            )
    }
}

/// La chat aperta dalla libreria o dalla scheda serie, a pagina intera.
struct CompanionScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chat: CompanionChat

    init(target: CompanionTarget) {
        _chat = State(initialValue: CompanionChat(target: target))
    }

    var body: some View {
        CompanionChatView(chat: chat, onClose: { dismiss() })
            .background(AppBackground())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
    }
}
