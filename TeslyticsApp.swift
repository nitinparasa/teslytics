//
//  TeslyticsApp.swift
//  Teslytics
//
//  Created by Nitin Parasa on 2026-04-01.
//

import SwiftUI

@main
struct TeslyticsApp: App {
    
    // Create one instance shared across the whole app
    @StateObject private var authService = TeslaAuthService()
    
    var body: some Scene {
        WindowGroup {
            if authService.isAuthenticated {
                ContentView(authService: authService)
                    .environmentObject(authService)
            } else {
                LoginView(authService: authService)
            }
        }
    }
}
