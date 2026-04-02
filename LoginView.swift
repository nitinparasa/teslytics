//
//  LoginView.swift
//  Teslytics
//
//  Created by Nitin Parasa on 2026-04-01.
//

import SwiftUI

// MARK: - Login Screen
struct LoginView: View {
    
    @ObservedObject var authService: TeslaAuthService
    
    var body: some View {
        ZStack {
            Color(.systemGray6)
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                Spacer()
                
                // Logo area
                VStack(spacing: 12) {
                    Text("⚡")
                        .font(.system(size: 80))
                    Text("Teslytics")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Your Tesla. Your data.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Error message
                if let error = authService.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                // Login button
                Button {
                    Task {
                        await authService.login()
                    }
                } label: {
                    HStack {
                        if authService.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Connect your Tesla")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.black)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .disabled(authService.isLoading)
                .padding(.horizontal)
                
                Text("Powered by Tesla Fleet API")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom)
            }
        }
    }
}

#Preview {
    LoginView(authService: TeslaAuthService())
}
