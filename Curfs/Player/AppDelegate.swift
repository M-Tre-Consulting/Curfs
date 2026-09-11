//
//  AppDelegate.swift
//  Curfs
//
//  Ponte minimo verso UIApplicationDelegate, necessario solo per
//  supportedInterfaceOrientations(for:): è il metodo che UIKit interpella
//  ogni volta che deve ridecidere gli orientamenti ammessi, incluso quando
//  l'app torna in primo piano dopo il background. Senza questo, in
//  un'app puramente SwiftUI-lifecycle non c'è modo di far "sopravvivere"
//  una rotazione richiesta esplicitamente (vedi OrientationController) a
//  quei momenti: UIKit ricadrebbe sempre sul default di Info.plist.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationController.currentMask
    }

    /// iOS risveglia l'app (anche se era terminata) per consegnare gli eventi
    /// della sessione di download in background: giriamo il completion handler
    /// di sistema a `RemoteDownloadManager`, che lo invocherà appena finito di
    /// processare i trasferimenti conclusi.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            RemoteDownloadManager.shared.handleBackgroundSessionEvents(
                identifier: identifier,
                completionHandler: completionHandler
            )
        }
    }
}
