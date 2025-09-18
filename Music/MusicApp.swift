//
//  MusicApp.swift
//  Music
//
//  Created by Ben on 9/17/25.
//

import SwiftUI
import UIKit
import QuartzCore

final class ProMotionManager {
    static let shared = ProMotionManager()
    private var displayLink: CADisplayLink?
    private init() {}
    @available(iOS 15.0, *)
    func start() {
        if displayLink != nil { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    @objc private func tick() { /* no-op; presence keeps range applied */ }
}

@main
struct MusicApp: App {
    let persistenceController = PersistenceController.shared
    @Environment(\.scenePhase) private var scenePhase

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
                .task { requestHighRefreshRate() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { requestHighRefreshRate() }
                }
        }
    }

    private func requestHighRefreshRate() {
        if #available(iOS 15.0, *) { ProMotionManager.shared.start() }
    }
}
