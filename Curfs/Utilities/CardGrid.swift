//
//  CardGrid.swift
//  Curfs
//
//  Colonne per le griglie di card (libreria e ricerca), calcolate dalla
//  larghezza REALE disponibile invece che con `GridItem(.adaptive(...))`.
//  L'adaptive, a certe larghezze — iPhone piccoli (12 mini / SE), Display
//  Zoom attivo, Dynamic Type grande — sceglie una colonna troppo larga e
//  lascia sforare le card oltre il bordo dello schermo. Qui invece si fissa
//  un numero intero di colonne `.flexible`, che si spartiscono lo spazio in
//  parti esatte e non possono mai eccedere. Minimo garantito: 2 colonne.
//

import SwiftUI

enum CardGrid {
    /// - Parameter width: larghezza già disponibile alla griglia (al netto
    ///   dei padding orizzontali del contenitore). 0 finché non è nota.
    static func columns(forWidth width: CGFloat,
                        spacing: CGFloat = 16,
                        targetCardWidth: CGFloat = 185) -> [GridItem] {
        let count: Int
        if width <= 0 {
            count = 2
        } else {
            count = max(2, Int((width + spacing) / (targetCardWidth + spacing)))
        }
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }
}
