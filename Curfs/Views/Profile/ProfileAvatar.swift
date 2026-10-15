//
//  ProfileAvatar.swift
//  Curfs
//
//  Foto del profilo (dal server) o, senza foto, le iniziali su un cerchio
//  viola. `ProfileToolbarButton` è il tasto in alto nella Libreria.
//

import SwiftUI
import ImageIO

struct ProfileAvatar: View {
    let profile: UserProfile?
    var size: CGFloat = 32
    /// Foto appena scelta nell'editor, non ancora caricata.
    var localImage: CGImage? = nil

    var body: some View {
        ZStack {
            if let localImage {
                Image(decorative: localImage, scale: 1).resizable().scaledToFill()
            } else if let profile, let url = ProfileSync.shared.avatarURL(for: profile) {
                RemoteImage(url: url) { initials }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder
    private var initials: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            if let profile {
                Text(verbatim: profile.initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

extension CGImage {
    /// Anteprima di un'immagine scelta dall'utente (rispetta l'orientamento EXIF).
    static func preview(from data: Data, maxPixels: Int = 600) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// Tasto del profilo nella barra della Libreria: apre la scheda dei profili.
struct ProfileToolbarButton: View {
    @State private var sync = ProfileSync.shared
    @State private var showProfiles = false

    var body: some View {
        Button {
            showProfiles = true
        } label: {
            if let profile = sync.active {
                ProfileAvatar(profile: profile, size: 28)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel(sync.active?.name ?? String(localized: "Profilo"))
        .help(sync.active?.name ?? String(localized: "Profilo"))
        .sheet(isPresented: $showProfiles) {
            ProfilesView()
        }
    }
}
