//
//  OrientationController.swift
//  Curfs
//
//  Forza la rotazione dell'interfaccia su richiesta esplicita dell'utente,
//  utile perché scavalca la levetta di blocco rotazione (che impedisce solo
//  la rotazione "fisica" automatica, non una richiesta esplicita dell'app).
//

import UIKit

@MainActor
enum OrientationController {
    /// L'orientamento attualmente desiderato dall'app: unica fonte di
    /// verità, consultata da AppDelegate.supportedInterfaceOrientations
    /// ogni volta che UIKit ha bisogno di ridecidere gli orientamenti
    /// ammessi (es. tornando dal background). Senza questo, in quei momenti
    /// UIKit ricade sul default dichiarato in Info.plist (verticale) e
    /// "dimentica" la rotazione esplicita richiesta in precedenza — è
    /// esattamente il bug per cui si rientrava sempre in verticale.
    private(set) static var currentMask: UIInterfaceOrientationMask = .portrait

    static func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        currentMask = mask

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }

        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(preferences) { _ in }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
