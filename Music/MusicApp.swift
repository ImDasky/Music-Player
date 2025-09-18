//
//  MusicApp.swift
//  Music
//
//  Created by Ben on 9/17/25.
//

import SwiftUI

@main
struct MusicApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
