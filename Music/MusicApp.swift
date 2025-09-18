//
//  MusicApp.swift
//  Music
//
//  Created by Ben on 9/17/25.
//

import SwiftUI
import UIKit

@main
struct MusicApp: App {
    let persistenceController = PersistenceController.shared

    init() {
        // Apply blurred dark appearance for tab bar on iOS 15/16
        if #available(iOS 17, *) {
            // iOS 17 has modern blur by default
        } else {
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
            appearance.backgroundColor = UIColor.black.withAlphaComponent(0.2)
            UITabBar.appearance().standardAppearance = appearance
            if #available(iOS 15.0, *) {
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
            UITabBar.appearance().tintColor = .white
            UITabBar.appearance().unselectedItemTintColor = UIColor(white: 1.0, alpha: 0.7)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
