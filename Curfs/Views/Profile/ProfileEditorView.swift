//
//  ProfileEditorView.swift
//  Curfs
//
//  Crea un profilo (profile == nil) o modifica quello esistente: nome e foto
//  facoltativa (ritagliata quadrata, vedi PosterImageProcessing.avatarJPEG).
//  Salva direttamente sul server.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct ProfileEditorView: View {
    let profile: UserProfile?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    /// Foto nuova già ritagliata, pronta da caricare.
    @State private var newAvatar: Data?
    @State private var newAvatarPreview: CGImage?
    @State private var removeAvatar = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var showFileImporter = false
    @State private var confirmDelete = false
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

    init(profile: UserProfile?) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasPhoto: Bool { newAvatar != nil || (profile?.avatar != nil && !removeAvatar) }

    /// Il profilo da mostrare nell'anteprima: senza foto se l'utente l'ha tolta.
    private var previewProfile: UserProfile {
        var p = profile ?? UserProfile(id: "", name: trimmedName, avatar: nil, created: nil)
        p.name = trimmedName.isEmpty ? "?" : trimmedName
        if removeAvatar { p.avatar = nil }
        return p
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    ProfileAvatar(profile: previewProfile, size: 96, localImage: newAvatarPreview)
                    photoButtons
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section {
                TextField("Nome", text: $name)
                    .autocorrectionDisabled()
            } header: {
                Text("Nome")
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            if profile != nil {
                Section {
                    Button("Elimina profilo", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Il profilo e il suo minutaggio vengono cancellati dal server, per tutti i dispositivi. La libreria di questo dispositivo resta com'è; se è il profilo in uso, dovrai sceglierne o crearne un altro.")
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .disabled(isWorking)
        .overlay {
            if isWorking { ProgressView().controlSize(.large) }
        }
        .navigationTitle(profile == nil ? String(localized: "Nuovo profilo") : String(localized: "Modifica profilo"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(profile == nil ? String(localized: "Crea") : String(localized: "Salva")) { save() }
                    .disabled(trimmedName.isEmpty || isWorking)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let data else {
                error = String(localized: "Impossibile leggere il file scelto.")
                return
            }
            Task { await useImage(data) }
        }
        #if os(iOS)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    error = String(localized: "Impossibile leggere la foto scelta.")
                    return
                }
                await useImage(data)
            }
        }
        #endif
        .confirmationDialog(
            "Eliminare il profilo \"\(profile?.name ?? "")\"?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) { delete() }
            Button("Annulla", role: .cancel) { }
        } message: {
            Text("Il minutaggio salvato in questo profilo andrà perso.")
        }
    }

    /// Su iPhone stretti (mini, SE, testo grande) i tre tasti con la scritta
    /// non ci stanno e andavano a capo lettera per lettera: se non entrano
    /// su una riga restano solo le icone.
    private var photoButtons: some View {
        ViewThatFits(in: .horizontal) {
            photoButtonRow.labelStyle(.titleAndIcon)
            photoButtonRow.labelStyle(.iconOnly)
        }
        .font(.subheadline)
    }

    private var photoButtonRow: some View {
        HStack(spacing: 10) {
            #if os(iOS)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Foto", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.glass)
            Button {
                showFileImporter = true
            } label: {
                Label("File", systemImage: "folder")
            }
            .buttonStyle(.glass)
            #else
            Button {
                showFileImporter = true
            } label: {
                Label("Scegli foto…", systemImage: "photo.badge.plus")
            }
            #endif
            if hasPhoto {
                Button(role: .destructive) {
                    newAvatar = nil
                    newAvatarPreview = nil
                    removeAvatar = true
                } label: {
                    Label("Togli", systemImage: "trash")
                }
                #if os(iOS)
                .buttonStyle(.glass)
                #endif
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func useImage(_ data: Data) async {
        guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
            PosterImageProcessing.avatarJPEG(from: data)
        }).value else {
            error = String(localized: "Questo file non sembra un'immagine valida.")
            return
        }
        newAvatar = jpeg
        newAvatarPreview = CGImage.preview(from: jpeg)
        removeAvatar = false
        error = nil
    }

    private func save() {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                if let profile {
                    try await ProfileSync.shared.update(profile, name: trimmedName, avatarJPEG: newAvatar, removeAvatar: removeAvatar)
                } else {
                    try await ProfileSync.shared.create(name: trimmedName, avatarJPEG: newAvatar)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func delete() {
        guard let profile else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await ProfileSync.shared.delete(profile)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
