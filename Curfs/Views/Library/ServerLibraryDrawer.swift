//
//  ServerLibraryDrawer.swift
//  Curfs
//
//  Il cassetto della Libreria del server (2026-11-28, voluto dall'utente al
//  posto della scheda Cerca): sul bordo destro della home c'è una pila di
//  dispositivi ammucchiati (TV, cassa, tablet, portatile, telefono); tirandola
//  verso sinistra dalla pila si apre un "portale" circolare con un bordo di
//  luce viola che si allarga seguendo il dito; dentro la Libreria emerge dal
//  nulla (parte ingrandita e sfocata e si mette a fuoco), i dispositivi
//  cavalcano il bordo del portale e si dissolvono, la home dietro si sfoca e
//  arretra. (Prima versione: pagina che entrava da destra ruotando come una
//  porta — bocciata dall'utente: "si apre come una pagina qualsiasi di un sito".) Tutto segue il dito (`progress` 0…1); lasciando
//  sopra il 35% (o con uno scatto veloce) si apre, sennò torna a posto. Un
//  tocco sulla pila la apre da solo. Si richiude col tasto in alto, con Esc
//  su Mac, o trascinando dal bordo sinistro della pagina verso destra.
//
//  La pagina ha la sua NavigationStack (le schede serie si aprono lì dentro)
//  e resta montata dopo la prima apertura, così ricorda ricerca e scorrimento.
//  Solo iPhone e Mac: la TV ha la sua barra a sinistra.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class ServerLibraryDrawer {
    static let shared = ServerLibraryDrawer()

    /// 0 = chiuso, 1 = aperto.
    var progress: CGFloat = 0
    /// La pila si vede solo sulla radice della home (non dentro una serie,
    /// non in altre schede): lo dice `LibraryHomeView`.
    var handleVisible = false
    /// La pagina si monta alla prima apertura e poi resta.
    private(set) var isMounted = false
    /// La pagina è sulla sua radice (non dentro una scheda serie).
    var pageAtRoot = true

    var isOpen: Bool { progress > 0.5 }

    private init() {}

    func mount() { if !isMounted { isMounted = true } }

    /// Curva quasi lineare: la forma del movimento la decide `PortalMath`,
    /// l'animazione dà solo il tempo. Più strada resta, più dura (mai meno
    /// di ~0,45 s, ~1 s da chiuso a aperto).
    private func settleAnimation(remaining: CGFloat, opening: Bool) -> Animation {
        let duration = opening ? 0.45 + 0.6 * remaining : 0.35 + 0.45 * remaining
        return .timingCurve(0.3, 0.05, 0.25, 1, duration: duration)
    }

    func open() {
        mount()
        withAnimation(settleAnimation(remaining: 1 - progress, opening: true)) { progress = 1 }
    }

    func close() {
        #if os(macOS)
        // Su Mac la barra in alto è della finestra: una pagina rimasta
        // montata (anche invisibile) ci lasciava i suoi tasti e la ricerca
        // sopra la home. A portale chiuso la si smonta.
        withAnimation(settleAnimation(remaining: progress, opening: false)) {
            progress = 0
        } completion: {
            if self.progress == 0 { self.isMounted = false }
        }
        #else
        withAnimation(settleAnimation(remaining: progress, opening: false)) { progress = 0 }
        #endif
    }

    /// Chiusa di colpo, senza animazione (cambio di scheda).
    func closeInstantly() {
        guard progress > 0 || isMounted else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = 0
            #if os(macOS)
            isMounted = false
            #endif
        }
    }

    func settle(open: Bool) {
        open ? self.open() : close()
    }
}

/// Geometria del portale, condivisa da pagina e pila.
enum PortalMath {
    static func clamp(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

    static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = clamp((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    static func easeOutCubic(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

    /// Centro del portale: la pila sul bordo destro.
    static func center(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width, y: DevicePile.handleFrame(in: size).midY)
    }

    /// Raggio che copre tutto lo schermo partendo dal centro del portale.
    static func fullRadius(in size: CGSize) -> CGFloat {
        let c = center(in: size)
        return hypot(max(c.x, size.width - c.x), max(c.y, size.height - c.y)) + 30
    }

    /// Prima si "accende" un globo sulla pila (subito, nei primi centimetri
    /// di trascinamento), poi il portale si allarga fino a coprire tutto.
    static func radius(_ p: CGFloat, in size: CGSize) -> CGFloat {
        let ignite = 52 * smoothstep(0, 0.12, p)
        let open = easeInOutCubic(clamp((p - 0.05) / 0.95))
        return ignite + (fullRadius(in: size) - ignite) * open
    }

    /// Quanto è "a fuoco" la pagina dentro il portale.
    static func focus(_ p: CGFloat) -> CGFloat { easeOutCubic(clamp((p - 0.1) / 0.9)) }
}

/// Avvolge il contenuto dell'app (le schede) e ci mette sopra la pila e la
/// pagina della Libreria.
struct ServerLibraryDrawerHost<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var drawer = ServerLibraryDrawer.shared
    @State private var dragStart: CGFloat?
    /// Vero finché il dito è giù, anche se il gesto viene ANNULLATO (iOS che
    /// se lo prende, la vista che sparisce...): in quel caso `onEnded` non
    /// arriva mai. Bug reale (2026-11-28, "sembra bloccata"): il portale
    /// restava fermo a metà, con home e Libreria entrambe non toccabili
    /// (ognuna lo è solo a portale chiuso/aperto). Visto col rapporto di un
    /// SIGABRT mandato all'app "bloccata": thread principale fermo e libero.
    @GestureState private var fingerDown = false
    @State private var thresholdHits = 0
    @State private var ignitions = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let p = drawer.progress
            ZStack {
                content
                    // La home arretra e si scurisce (solo scala e un velo
                    // nero: niente sfocatura, costava un ridisegno a fotogramma).
                    .scaleEffect(reduceMotion ? 1 : 1 - 0.07 * p)
                    .overlay {
                        Color.black.opacity(0.55 * p)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                    .allowsHitTesting(p < 0.02)
                    .accessibilityHidden(p > 0.5)

                if drawer.isMounted {
                    PortalPage(progress: p, size: size, reduceMotion: reduceMotion)
                        .allowsHitTesting(p > 0.98)
                        .accessibilityHidden(p < 0.5)
                        .overlay(alignment: .leading) {
                            // Bordo sinistro: trascinando verso destra si
                            // richiude (solo sulla radice: dentro una serie
                            // c'è il "indietro" di sistema).
                            // Resta montato finché si trascina: se sparisse
                            // a metà gesto, il gesto verrebbe annullato.
                            if (p > 0.98 && drawer.pageAtRoot) || dragStart != nil {
                                Color.clear
                                    .frame(width: 22)
                                    .contentShape(Rectangle())
                                    .gesture(closeDrag(width: size.width))
                            }
                        }
                }

                DevicePile(progress: p, size: size, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
                    .opacity(drawer.handleVisible || p > 0.001 ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: drawer.handleVisible)

                handle(size: size)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: thresholdHits)
            .onChange(of: fingerDown) { _, down in
                // Gesto finito o annullato: se `onEnded` non l'ha già chiuso,
                // si completa da qui (sopra metà si apre, sotto si chiude).
                guard !down, dragStart != nil else { return }
                dragStart = nil
                drawer.settle(open: drawer.progress > 0.5)
            }
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: ignitions)
        }
        #if os(iOS)
        // Su iPhone il portale copre tutto lo schermo. Su Mac no: il
        // contenuto finiva sotto la barra della finestra (titolo sparito,
        // testo sotto i tre pallini).
        .ignoresSafeArea()
        #endif
    }

    // MARK: Gesti

    /// Zona sensibile della pila sul bordo destro.
    private func handle(size: CGSize) -> some View {
        let frame = DevicePile.handleFrame(in: size)
        return Color.clear
            .frame(width: frame.width + 24, height: frame.height + 40)
            .contentShape(Rectangle())
            .gesture(openDrag(width: size.width))
            .onTapGesture { ignitions += 1; drawer.open() }
            .accessibilityElement()
            .accessibilityLabel("Apri la libreria")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { drawer.open() }
            // Toccabile da chiusa e per tutto il trascinamento: prima si
            // spegneva appena superato il 2% e iOS a volte annullava il gesto.
            .allowsHitTesting((drawer.handleVisible && drawer.progress < 0.02) || dragStart != nil)
            .position(x: size.width - (frame.width + 24) / 2, y: frame.midY)
    }

    private func openDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($fingerDown) { _, state, _ in state = true }
            .onChanged { value in
                if dragStart == nil { dragStart = drawer.progress; drawer.mount(); ignitions += 1 }
                let previous = drawer.progress
                let next = min(max((dragStart ?? 0) + -value.translation.width / (width * 0.8), 0), 1)
                drawer.progress = next
                if (previous < 0.35) != (next < 0.35) { thresholdHits += 1 }
            }
            .onEnded { value in
                dragStart = nil
                let predicted = -value.predictedEndTranslation.width / width
                drawer.settle(open: drawer.progress > 0.35 || predicted > 0.6)
            }
    }

    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($fingerDown) { _, state, _ in state = true }
            .onChanged { value in
                if dragStart == nil { dragStart = drawer.progress }
                let previous = drawer.progress
                let next = min(max((dragStart ?? 1) - value.translation.width / width, 0), 1)
                drawer.progress = next
                if (previous < 0.65) != (next < 0.65) { thresholdHits += 1 }
            }
            .onEnded { value in
                dragStart = nil
                let predicted = value.predictedEndTranslation.width / width
                drawer.settle(open: !(drawer.progress < 0.65 || predicted > 0.5))
            }
    }
}

// MARK: - Il portale

/// La pagina della Libreria dentro il portale che si allarga dalla pila, col
/// suo bordo di luce. `Animatable`: il corpo si ricalcola a ogni fotogramma
/// anche durante le animazioni di rilascio. `ServerLibraryView()` non ha
/// parametri, quindi non si ridisegna: cambiano solo gli effetti sopra.
private struct PortalPage: View, Animatable {
    var progress: CGFloat
    let size: CGSize
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = progress
        let center = PortalMath.center(in: size)
        let radius = PortalMath.radius(p, in: size)
        let focus = PortalMath.focus(p)
        let anchor = UnitPoint(x: 1, y: center.y / max(size.height, 1))
        let edgeFade = 1 - PortalMath.smoothstep(0.7, 0.98, p)

        return ZStack {
            ServerLibraryView()
                .frame(width: size.width, height: size.height)
                // Emerge dal portale: arriva da più vicino e si posa.
                .scaleEffect(reduceMotion ? 1 : 1.16 - 0.16 * focus, anchor: anchor)
                .opacity(Double(reduceMotion ? p : PortalMath.smoothstep(0.02, 0.4, p)))
                // Ritaglio con una forma, non `.mask`: la maschera su una
                // pagina col vetro costringeva a ricomporla fuori schermo a
                // ogni fotogramma (4 fps a portale grande).
                .clipShape(PortalShape(center: center, radius: reduceMotion || p > 0.995 ? .infinity : radius))

            if !reduceMotion, p > 0.001, p < 0.995 {
                glassRim(center: center, radius: radius, p: p, edgeFade: edgeFade)
                    .allowsHitTesting(false)
                glow(center: center, radius: radius, p: p, edgeFade: edgeFade)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(p > 0.001 ? 1 : 0)
    }

    /// Sfocatura solo verso l'interno della cornice: UNA fascia di
    /// materiale di sistema (sfocatura a raggio fisso) sfumata in modo
    /// continuo da una maschera radiale, piena sul bordo e nulla verso il
    /// centro. Prima c'erano tre fasce di opacità diverse ("a scalini") e un
    /// `glassEffect` su una corona gigante che cambiava forma a ogni
    /// fotogramma: non si vedeva ed era il primo indiziato delle chiusure
    /// dell'app durante l'animazione.
    @ViewBuilder
    private func glassRim(center: CGPoint, radius: CGFloat, p: CGFloat, edgeFade: CGFloat) -> some View {
        let soft = 1 - PortalMath.focus(p)
        let band = 50 + 70 * soft
        let inner = max(radius - band, 0)
        RingShape(center: center, outer: radius, inner: inner)
            .fill(.ultraThinMaterial)
            .mask {
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: radius > 0 ? inner / radius : 0),
                        .init(color: .black.opacity(0.55), location: radius > 0 ? (inner + band * 0.55) / radius : 0),
                        .init(color: .black, location: 1),
                    ],
                    center: UnitPoint(x: center.x / max(size.width, 1), y: center.y / max(size.height, 1)),
                    startRadius: 0, endRadius: max(radius, 1)
                )
            }
            .frame(width: size.width, height: size.height)
            .opacity(Double(edgeFade))
    }

    /// Bordo di luce: tre anelli (niente blur, niente modalità di fusione:
    /// `plusLighter` ricomponeva tutto lo schermo sotto a ogni fotogramma,
    /// e il vecchio bagliore interno era un gradiente grande quanto lo
    /// schermo), e il globo che si accende sulla pila all'inizio. Il tutto
    /// in un solo strato Metal (`drawingGroup`), sono solo forme.
    @ViewBuilder
    private func glow(center: CGPoint, radius: CGFloat, p: CGFloat, edgeFade: CGFloat) -> some View {
        let spin = Angle.degrees(Double(p) * 260)
        let colors = [Color.accentColor, .white, Color(red: 0.42, green: 0.36, blue: 1), Color(red: 0.9, green: 0.45, blue: 1), Color.accentColor]
        let ignite = PortalMath.smoothstep(0, 0.1, p) * (1 - PortalMath.smoothstep(0.12, 0.45, p))
        let soft = 1 - PortalMath.focus(p)

        ZStack {
            // Bagliore verso l'interno: anello largo e tenue appena dentro il bordo.
            Circle()
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 40 + 50 * soft)
                .frame(width: max(radius * 2 - 40 - 50 * soft, 0), height: max(radius * 2 - 40 - 50 * soft, 0))
                .position(center)

            // Alone.
            Circle()
                .stroke(AngularGradient(colors: colors, center: .center, angle: spin),
                        lineWidth: 10 + 22 * soft)
                .frame(width: radius * 2, height: radius * 2)
                .position(center)
                .opacity(0.32)

            // Cornice di vetro: corpo chiaro e sottile, riflesso bianco che
            // gira (luce che scorre sul vetro), filo scuro all'interno per
            // lo spessore, filo di luce colorato sopra.
            Circle()
                .stroke(.white.opacity(0.10), lineWidth: 14)
                .frame(width: radius * 2, height: radius * 2)
                .position(center)
            Circle()
                .stroke(AngularGradient(stops: [
                    .init(color: .white.opacity(0.0), location: 0),
                    .init(color: .white.opacity(0.85), location: 0.12),
                    .init(color: .white.opacity(0.0), location: 0.3),
                    .init(color: .white.opacity(0.0), location: 0.55),
                    .init(color: .white.opacity(0.5), location: 0.66),
                    .init(color: .white.opacity(0.0), location: 0.8),
                ], center: .center, angle: .degrees(Double(p) * -180)), lineWidth: 5)
                .frame(width: radius * 2 - 6, height: radius * 2 - 6)
                .position(center)
            Circle()
                .stroke(.black.opacity(0.25), lineWidth: 1.5)
                .frame(width: max(radius * 2 - 15, 0), height: max(radius * 2 - 15, 0))
                .position(center)
            Circle()
                .stroke(AngularGradient(colors: colors, center: .center, angle: spin), lineWidth: 2)
                .frame(width: radius * 2 + 12, height: radius * 2 + 12)
                .position(center)

            // Il globo che si accende sulla pila.
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.95), Color.accentColor.opacity(0.7), .clear],
                                     center: .center, startRadius: 0, endRadius: 90))
                .frame(width: 180, height: 180)
                .scaleEffect(0.4 + 0.9 * ignite)
                .position(center)
                .opacity(Double(ignite))
        }
        .frame(width: size.width, height: size.height)
        .opacity(Double(edgeFade))
        .drawingGroup()
    }
}

/// Corona circolare (buco al centro), per la fascia sfocata e il vetro.
private struct RingShape: Shape {
    var center: CGPoint
    var outer: CGFloat
    var inner: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard outer > 0 else { return path }
        path.addArc(center: center, radius: outer, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        path.closeSubpath()
        if inner > 0 {
            // Verso opposto: con il riempimento normale resta il buco.
            path.addArc(center: center, radius: inner, startAngle: .zero, endAngle: .degrees(-360), clockwise: true)
            path.closeSubpath()
        }
        return path
    }
}

/// Il cerchio del portale come forma di ritaglio; con raggio infinito è
/// tutto il riquadro (portale aperto).
private struct PortalShape: Shape {
    var center: CGPoint
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard radius.isFinite else { return Path(rect) }
        return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

// MARK: - La pila di dispositivi

/// TV, cassa, tablet, portatile e telefono ammucchiati sul bordo destro,
/// che si staccano uno dopo l'altro e cavalcano il bordo del portale a
/// ventaglio, poi svaniscono. Disegno puro (niente tocchi): la zona sensibile
/// è in `ServerLibraryDrawerHost.handle`. `Animatable` come il portale.
struct DevicePile: View, Animatable {
    var progress: CGFloat
    let size: CGSize
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    @State private var nudge: CGFloat = 0

    private struct Device {
        let symbol: String
        let rest: CGPoint      // posizione nella pila, rispetto al centro della linguetta
        let restAngle: Double
        let spin: Double
        let pointSize: CGFloat
    }

    private static let devices: [Device] = [
        Device(symbol: "tv", rest: CGPoint(x: -2, y: -50), restAngle: -9, spin: -34, pointSize: 22),
        Device(symbol: "hifispeaker.fill", rest: CGPoint(x: 5, y: -22), restAngle: 12, spin: 40, pointSize: 19),
        Device(symbol: "ipad.landscape", rest: CGPoint(x: -4, y: 4), restAngle: -15, spin: -26, pointSize: 21),
        Device(symbol: "laptopcomputer", rest: CGPoint(x: 4, y: 30), restAngle: 7, spin: 30, pointSize: 21),
        Device(symbol: "iphone", rest: CGPoint(x: -3, y: 55), restAngle: -6, spin: -46, pointSize: 19),
    ]

    /// Linguetta in vetro da cui spunta la pila: ne resta fuori dallo
    /// schermo quasi metà, come qualcosa da tirare.
    static func handleFrame(in size: CGSize) -> CGRect {
        let width: CGFloat = 58, height: CGFloat = 168
        let visible: CGFloat = 36
        let midY = size.height * 0.56
        return CGRect(x: size.width - visible, y: midY - height / 2, width: width, height: height)
    }

    var body: some View {
        let frame = Self.handleFrame(in: size)
        let p = progress
        // La linguetta si gonfia appena la si tira e poi "scoppia" nel globo.
        let swell = PortalMath.smoothstep(0, 0.1, p)
        let pop = PortalMath.smoothstep(0.06, 0.22, p)
        ZStack {
            Capsule()
                .fill(.clear)
                .frame(width: frame.width, height: frame.height)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.25 + 0.35 * swell)), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.12 + 0.4 * swell), lineWidth: 0.5))
                .scaleEffect(reduceMotion ? 1 : 1 + 0.18 * swell + 0.5 * pop)
                .position(x: frame.midX - 10 * swell + nudge, y: frame.midY)
                .opacity(Double(1 - pop))

            // Icone in un solo strato Metal (sono solo simboli e ombre).
            ZStack {
                ForEach(Array(Self.devices.enumerated()), id: \.offset) { index, device in
                    deviceView(device, index: index, frame: frame, p: p)
                }
            }
            .frame(width: size.width, height: size.height)
            .drawingGroup()
        }
        .frame(width: size.width, height: size.height)
        .task(id: progress == 0) {
            // Ogni tanto la pila fa capolino verso sinistra, per far capire
            // che si tira. Solo da chiusa.
            guard progress == 0, !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(1.2))
            while !Task.isCancelled {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { nudge = -9 }
                try? await Task.sleep(for: .seconds(0.28))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { nudge = 0 }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private func deviceView(_ device: Device, index: Int, frame: CGRect, p: CGFloat) -> some View {
        // Si staccano uno dopo l'altro (la pila "si sfoglia"), poi ognuno
        // cavalca il bordo del portale nella sua direzione del ventaglio.
        let delay = CGFloat(index) * 0.035
        let local = PortalMath.clamp((p - delay) / (1 - delay))
        let radius = PortalMath.radius(local, in: size)

        // Ventaglio verso sinistra, da 128° a 232°.
        let degrees = 128 + Double(index) * 26
        let dx = CGFloat(cos(degrees * .pi / 180)), dy = CGFloat(-sin(degrees * .pi / 180))
        let restX = frame.midX + device.rest.x + nudge * (1 + CGFloat(index) * 0.15)
        let restY = frame.midY + device.rest.y
        // Nel primo tratto escono dalla pila con un piccolo salto, poi
        // restano appena dentro il bordo del portale.
        let hop = 18 * PortalMath.smoothstep(0, 0.1, local)
        let x = restX + dx * (radius * 0.93 + hop)
        let y = restY + dy * (radius * 0.93 + hop)
        let ride = PortalMath.focus(local)
        let angle = device.restAngle + Double(ride) * device.spin
        let scale = 1 + 0.25 * PortalMath.smoothstep(0, 0.1, local) + 1.3 * ride
        let fade = PortalMath.smoothstep(0.5, 0.88, local)

        return Image(systemName: device.symbol)
            .font(.system(size: device.pointSize, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .shadow(color: Color.accentColor.opacity(0.9), radius: 9)
            .scaleEffect(reduceMotion ? 1 : scale)
            .rotationEffect(.degrees(reduceMotion ? device.restAngle : angle))
            .position(x: reduceMotion ? restX : x, y: reduceMotion ? restY : y)
            .opacity(Double(reduceMotion ? 1 - p : 1 - fade))
    }
}
