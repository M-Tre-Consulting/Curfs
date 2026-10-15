//
//  ProfileSwitcher.swift
//  Curfs
//
//  Riga delle foto profilo nella scheda Profili: il profilo attivo è il
//  primo, più grande e cerchiato; toccandone un altro i due si scambiano di
//  posto. Durante lo scambio quello che entra passa sopra e quello che esce
//  sotto (un arco ciascuno), così non si scontrano a metà strada.
//

import SwiftUI

/// Uno scambio in corso: chi entra e chi esce (nil = nessun profilo prima).
struct ProfileSwap: Equatable {
    let id = UUID()
    let incoming: String
    let outgoing: String?
}

struct ProfileSwitcher: View {
    let profiles: [UserProfile]
    let activeID: String?
    let swap: ProfileSwap?
    let onSelect: (UserProfile) -> Void

    static let animation = Animation.spring(duration: 0.55, bounce: 0.22)

    private var ordered: [UserProfile] {
        guard let activeID, let active = profiles.first(where: { $0.id == activeID }) else { return profiles }
        return [active] + profiles.filter { $0.id != activeID }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(ordered) { profile in
                    tile(profile)
                }
            }
            // Spazio per l'arco dello scambio e per il cerchio del profilo attivo.
            .padding(.vertical, 22)
            .padding(.horizontal, 6)
        }
        .scrollClipDisabled()
    }

    private func tile(_ profile: UserProfile) -> some View {
        let isActive = profile.id == activeID
        let lift: CGFloat = profile.id == swap?.incoming ? -26 : (profile.id == swap?.outgoing ? 26 : 0)
        return VStack(spacing: 8) {
            ProfileAvatar(profile: profile, size: isActive ? 84 : 58)
                .padding(4)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: isActive ? 3 : 0))
            Text(profile.name)
                .font(isActive ? .subheadline.weight(.semibold) : .caption)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(width: isActive ? 100 : 74)
        .contentShape(Rectangle())
        .keyframeAnimator(initialValue: 0.0, trigger: swap?.id) { content, progress in
            content.offset(y: lift * progress)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1, duration: 0.24)
                CubicKeyframe(0, duration: 0.34)
            }
        }
        // Chi entra passa davanti.
        .zIndex(profile.id == swap?.incoming ? 1 : 0)
        .onTapGesture {
            if !isActive { onSelect(profile) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isSelected] : [.isButton])
    }
}
