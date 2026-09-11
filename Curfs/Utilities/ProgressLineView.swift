//
//  ProgressLineView.swift
//  Curfs
//
//  La lineetta sottile che indica quanto di un video è già stato guardato,
//  sovrapposta al bordo inferiore delle miniature in libreria.
//

import SwiftUI

struct ProgressLineView: View {
    var fraction: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.28))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}
