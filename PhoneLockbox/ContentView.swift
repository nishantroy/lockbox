import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = ScreenTimeCoordinator()
    @State private var selectedTab = 0
    @State private var lockboxPath: [QuickActionRoute.Destination] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $lockboxPath) {
                LockboxTabView(coordinator: coordinator, navigationPath: $lockboxPath)
                    .navigationDestination(for: QuickActionRoute.Destination.self) { destination in
                        switch destination {
                        case .recovery:
                            RecoveryView(coordinator: coordinator) { pending in
                                guard let pending,
                                      case .recovery = pending.action else { return }
                                coordinator.acknowledgePresentedQuickAction(pending)
                            }
                        }
                    }
            }
            .tabItem {
                Label("Lockbox", systemImage: "lock.shield")
            }
            .tag(0)

            // This tab intentionally has no authorization gate. A companion
            // user can read the recovery explanation without Screen Time.
            NavigationStack {
                PeopleView()
            }
            .tabItem {
                Label("People", systemImage: "person.2")
            }
            .tag(1)

            NavigationStack {
                SettingsView(coordinator: coordinator)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(2)
        }
        .tint(LockboxTheme.accent)
        .lockboxScreen()
        .onOpenURL { url in
            selectedTab = 0
            lockboxPath = []
            coordinator.handleQuickActionURL(url)
        }
        .task {
            coordinator.refreshAuthorization()
            routePendingQuickActionIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.refreshAuthorization()
                routePendingQuickActionIfNeeded()
            }
        }
    }

    private func routePendingQuickActionIfNeeded() {
        // Every queued route is navigation-only. Selecting the Lockbox tab and
        // clearing an old recovery path happen before claiming presentation;
        // enforcement and recovery state remain untouched.
        selectedTab = 0
        lockboxPath = []
        coordinator.processPendingQuickActionRoute()
    }

    @Environment(\.scenePhase) private var scenePhase
}

#Preview {
    ContentView()
}
