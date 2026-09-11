//
//  StreamingBadge.swift
//  Curfs
//
//  Pastiglia "streaming" sulle card della libreria: distingue le voci che
//  vivono sul server remoto (nessun file scaricato) da quelle in locale.
//

import SwiftUI

struct StreamingBadge: View {
    var body: some View {
        Image(systemName: "wifi")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))
            .padding(6)
    }
}
