//
//  Branding.swift
//  Curfs
//
//  Firma, informativa sulla privacy e licenza di M-Tre Consulting, secondo la
//  guida in `brand/README.md` della repo M-Tre-Consulting/m-tre-site (stessa
//  struttura di MarkIt). La firma sta in fondo alla Libreria su entrambe le
//  piattaforme; la schermata legale si apre dall'anno della firma, dal pulsante
//  ⓘ della Libreria su iPhone e dal menu Curfs su Mac.
//

import SwiftUI

/// Chi fa Curfs: nome, sito e contatti di M-Tre Consulting.
enum MTre {
    static let name = "M-Tre Consulting"
    static let site = URL(string: "https://mtre-consulting.it")!
    static let email = "info@mtre-consulting.it"
    static let owners = [
        "Simone Rolando – P.IVA 01866720095",
        "Nicolò Perri – P.IVA 01949510091",
        "Emad Alaa Soliman Mohamed Soliman – P.IVA 01949520090",
    ]
    static var year: Int { Calendar.current.component(.year, from: Date()) }
    static var copyright: String { "© \(year) \(name)" }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// Firma in basso: logo e nome a sinistra (portano al sito), copyright e anno a destra
/// (aprono le informazioni legali).
struct BrandFooter: View {
    var onInfo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Link(destination: MTre.site) {
                HStack(spacing: 6) {
                    Image("MTreLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                    Text(verbatim: MTre.name)
                }
            }
            .help(Text(verbatim: MTre.site.absoluteString))
            Spacer(minLength: 8)
            Button(action: onInfo) {
                Text(verbatim: "© \(MTre.year)")
            }
            .help(Text("Privacy, licenza e contatti"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

/// Informazioni legali: chi siamo, informativa sulla privacy dell'app, licenza, contatti.
struct LegalView: View {
    var appName = "Curfs"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image("MTreLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: appName)
                            .font(.title2.bold())
                        Text("Versione \(MTre.appVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("\(MTre.copyright). Tutti i diritti riservati.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                section("Informativa sulla privacy") {
                    paragraph("Curfs non raccoglie dati personali e non li invia a M-Tre Consulting. Non ci sono account, pubblicità, statistiche o tracciamento.")
                    paragraph("La libreria resta sul dispositivo, nella cartella dell'app: i video che importi (Curfs ne fa una copia; su Mac nella cartella Library dentro Documenti), l'avanzamento di visione, le miniature e l'analisi di sigle e titoli di coda. Dai File, Curfs legge solo i file e le cartelle che scegli tu; dalle Foto, solo l'immagine che scegli come copertina.")
                    paragraph("La sezione Cerca si collega soltanto al server che configuri tu (per esempio uno di casa tua). Indirizzo, nome utente e password restano nelle impostazioni dell'app sul dispositivo. Verso quel server passano gli elenchi delle cartelle, i video in streaming o scaricati e le copertine che carichi.")
                    paragraph("Per trovare le locandine, Curfs invia il solo titolo di film e serie a Wikipedia (Wikimedia Foundation), IMDb e la ricerca di iTunes di Apple, e scarica le immagini da lì. Questi servizi ricevono il titolo e, come per ogni connessione, l'indirizzo IP; nessun altro dato.")
                    paragraph("Puoi chiederci informazioni ed esercitare i tuoi diritti previsti dal GDPR (Regolamento UE 2016/679) scrivendo a \(MTre.email). Poiché non conserviamo i tuoi dati, eliminare l'app cancella tutto (su Mac, elimina anche la cartella Library dentro Documenti). I file sul tuo server restano tuoi e non vengono toccati.")
                }

                section("Titolare") {
                    Text(verbatim: "\(MTre.name), Savona, Italia")
                    ForEach(MTre.owners, id: \.self) { Text(verbatim: $0).foregroundStyle(.secondary) }
                }

                section("Licenza") {
                    paragraph("Curfs è software open source di M-Tre Consulting, distribuito con licenza MIT: puoi usarlo, copiarlo, modificarlo e distribuirlo mantenendo l'avviso di copyright e il testo della licenza, che trovi nel file LICENSE della repo.")
                    Link(destination: URL(string: "https://github.com/M-Tre-Consulting/Curfs")!) {
                        Text(verbatim: "github.com/M-Tre-Consulting/Curfs")
                    }
                    paragraph("Il riconoscimento di sigle e titoli di coda si basa sul difference hash (dHash) di Neal Krawetz. Le locandine appartengono ai rispettivi titolari e provengono da Wikipedia, IMDb e iTunes.")
                }

                section("Contatti") {
                    Link(destination: MTre.site) { Text(verbatim: MTre.site.absoluteString) }
                    Link(destination: URL(string: "mailto:\(MTre.email)")!) { Text(verbatim: MTre.email) }
                }

                Text("Aggiornata il 29 settembre 2026.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func paragraph(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `LegalView` presentata come foglio, con il tasto per chiuderla.
struct LegalSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LegalView()
                .navigationTitle("Privacy, licenza e contatti")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Chiudi") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}
