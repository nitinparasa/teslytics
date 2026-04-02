import SwiftUI

// MARK: - Info Card Component
struct InfoCard: View {
    var icon: String
    var title: String
    var value: String
    var subtitle: String
    
    var body: some View {
        VStack(spacing: 12) {
            Text(icon + " " + title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 52, weight: .bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 10)
        .padding(.horizontal)
    }
}

// MARK: - Dashboard Screen
struct DashboardView: View {
    
    @StateObject private var apiService: TeslaAPIService
    @State private var vehicle: Vehicle = Vehicle.sample
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    init(authService: TeslaAuthService) {
        _apiService = StateObject(
            wrappedValue: TeslaAPIService(authService: authService)
        )
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGray6)
                    .ignoresSafeArea()
                
                if isLoading {
                    ProgressView("Fetching your Tesla...")
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            
                            // Error banner
                            if let error = errorMessage {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Color.red.opacity(0.8))
                                    .cornerRadius(10)
                                    .padding(.horizontal)
                            }
                            
                            // Battery Card
                            InfoCard(
                                icon: "🔋",
                                title: "Battery",
                                value: vehicle.batteryLevelText,
                                subtitle: vehicle.rangeText
                            )
                            
                            // Status Card
                            InfoCard(
                                icon: vehicle.statusIcon,
                                title: "Status",
                                value: vehicle.statusText,
                                subtitle: vehicle.isCharging ? "Charging now" : "Last updated just now"
                            )
                            
                            // Odometer Card
                            InfoCard(
                                icon: "🛣️",
                                title: "Odometer",
                                value: "\(Int(vehicle.odometer)) km",
                                subtitle: "Software \(vehicle.softwareVersion)"
                            )
                        }
                        .padding(.vertical)
                    }
                    .refreshable {
                        await loadVehicleData()
                    }
                }
            }
            .navigationTitle(vehicle.name)
            .task {
                await loadVehicleData()
            }
        }
    }
    
    // MARK: - Load Real Data
    func loadVehicleData() async {
        isLoading = true
        errorMessage = nil
        
        do {
            // 1. Get list of vehicles on the account
            let vehicles = try await apiService.fetchVehicles()
            
            guard let first = vehicles.first else {
                errorMessage = "No vehicles found on your account"
                isLoading = false
                return
            }
            
            print("🚗 Found: \(first.displayName) - \(first.state)")
            
            // 2. Only fetch state if vehicle is online
            guard first.isOnline else {
                errorMessage = "\(first.stateIcon) Your Tesla is \(first.state) - open the Tesla app to wake it"
                isLoading = false
                return
            }
            
            // 3. Fetch full vehicle data
            let state = try await apiService.fetchVehicleState(id: String(first.id))
            
            // 4. Map API response to our Vehicle model
            vehicle = Vehicle(
                name: first.displayName,
                batteryLevel: Double(state.chargeState.batteryLevel),
                range: state.chargeState.rangeKm,
                isCharging: state.chargeState.isCharging,
                odometer: state.vehicleState.odometerKm,
                softwareVersion: state.vehicleState.softwareUpdate?.version ?? "Unknown"
            )
            
        } catch {
            errorMessage = error.localizedDescription
            print("❌ Error: \(error)")
        }
        
        isLoading = false
    }
}

// MARK: - Root Tab View
struct ContentView: View {
    var authService: TeslaAuthService
    var body: some View {
        TabView {
            DashboardView(authService: authService)
                .tabItem {
                    Label("Dashboard", systemImage: "car.fill")
                }
            
            NavigationStack {
                DrivesView(drives: Drive.samples)
            }
            .tabItem {
                Label("Drives", systemImage: "road.lanes")
            }
        }
    }
}

#Preview {
    ContentView(authService: TeslaAuthService())
}
