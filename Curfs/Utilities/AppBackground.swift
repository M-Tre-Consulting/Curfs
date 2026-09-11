//
//  AppBackground.swift
//  Curfs
//
//  Sfondo immersivo viola scuro con qualche "luce" sfocata: dietro ci vanno
//  le superfici in Liquid Glass, che su questo tipo di fondo rendono al meglio.
//

import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.02, blue: 0.06)

            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.06, blue: 0.26),
                    Color(red: 0.05, green: 0.02, blue: 0.10),
                    Color(red: 0.02, green: 0.01, blue: 0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(Color(red: 0.62, green: 0.30, blue: 0.98).opacity(0.38))
                .frame(width: 440, height: 440)
                .blur(radius: 130)
                .offset(x: -150, y: -300)

            Circle()
                .fill(Color(red: 0.45, green: 0.15, blue: 0.85).opacity(0.30))
                .frame(width: 380, height: 380)
                .blur(radius: 140)
                .offset(x: 170, y: 260)

            Circle()
                .fill(Color(red: 0.30, green: 0.35, blue: 0.95).opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 120)
                .offset(x: 130, y: -520)
        }
        .ignoresSafeArea()
    }
}
