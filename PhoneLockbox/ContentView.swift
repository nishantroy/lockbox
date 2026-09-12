import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = ScreenTimeCoordinator()

    var body: some View {
        TabView {
            NavigationStack {
                LockboxTabView(coordinator: coordinator)
            }
            .tabItem {
                Label("Lockbox", systemImage: "lock.shield")
            }

            // This tab intentionally has no authorization gate. A companion
            // user can read the recovery explanation without Screen Time.
            NavigationStack {
                PeopleView()
            }
            .tabItem {
                Label("People", systemImage: "person.2")
            }

            NavigationStack {
                SettingsView(coordinator: coordinator)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .task { coordinator.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.refreshAuthorization()
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
}

#Preview {
    ContentView()
}
