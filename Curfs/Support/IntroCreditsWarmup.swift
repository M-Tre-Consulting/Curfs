//
//  IntroCreditsWarmup.swift
//  Curfs
//
//  All'avvio dell'app, in background e a bassa priorità, calcola e mette in
//  cache l'analisi "salta intro" per TUTTA la libreria locale. È la garanzia
//  che — dopo che l'app è stata aperta qualche minuto almeno una volta — il
//  pulsante compaia alla PRIMA riproduzione di qualunque episodio, invece di
//  dover rincorrere l'analisi mentre la sigla è già in corso.
//
//  Il lavoro lo fa `IntroAnalysisQueue` (indipendente da qualunque
//  schermata); gli episodi già in cache costano solo una lettura di un
//  piccolo JSON.
//

import Foundation

@MainActor
enum IntroCreditsWarmup {
    static func run() async {
        // Lascia sfilare l'avvio e un eventuale import appena lanciato.
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        IntroAnalysisQueue.shared.enqueueLibrary()
    }
}
