//
//  CurfsApp.swift
//  Curfs
//
//  Created by Nicolò Perri on 13/8/26.
//

import SwiftUI
import SwiftData

@main
struct CurfsApp: App {
    // Serve solo per supportedInterfaceOrientations(for:), vedi AppDelegate.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(AppModelContainer.shared)
    }
}
