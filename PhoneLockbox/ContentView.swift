import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = ScreenTimeCoordinator()
    @StateObject private var companion = CompanionCoordinator()
    @State private var selectedTab = 0
    @State private var lockboxPath: [QuickActionRoute.Destination] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $lockboxPath) {
                LockboxTabView(coordinator: coordinator, companion: companion, navigationPath: $lockboxPath)
                    .navigationDestination(for: QuickActionRoute.Destination.self) { destination in
                        switch destination {
                        case .recovery:
                            RecoveryView(
                                coordinator: coordinator,
                                onPresented: { pending in
                                    guard let pending,
                                          case .recovery = pending.action else { return }
                                    _ = coordinator.acknowledgePresentedQuickAction(pending)
                                },
                                onDismissed: { pending in
                                    guard let pending,
                                          case .recovery = pending.action else { return }
                                    _ = coordinator.settlePresentedQuickAction(pending)
                                }
                            )
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
                PeopleView(coordinator: coordinator, companion: companion)
            }
            .tabItem {
                Label("People", systemImage: "person.2")
            }
            .tag(1)

            NavigationStack {
                SettingsView(coordinator: coordinator, companion: companion)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(2)
        }
        .tint(LockboxTheme.accent)
        .lockboxScreen()
        .onOpenURL { url in
            // A `phone-lockbox-companion://invite/...` link (shared via the
            // People tab, whether this device created the invite or a
            // friend shared theirs) routes to People with the "Paste invite
            // link" field prefilled. It never auto-accepts anything.
            if companion.handleIncomingCompanionLink(url) {
                selectedTab = 1
                return
            }
            selectedTab = 0
            lockboxPath = []
            coordinator.handleQuickActionURL(url)
        }
        .task {
            coordinator.refreshAuthorization()
            coordinator.processPendingQuickActionRoute()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.refreshAuthorization()
                // Scene reactivation is an explicit additional retry trigger
                // for the durable Quick Action queue (docs/quick-actions.md),
                // independent of whether anything is actually pending — this
                // call must run every time. It must NOT, by itself, switch
                // tabs or clear the Lockbox nav path; see the `onChange`
                // below for that.
                coordinator.processPendingQuickActionRoute()
                // R5 Slice B2c review, P2-4: finish an interrupted friend
                // release on every foreground, not only from the People tab.
                Task { await companion.replayPendingFriendRelease(coordinator: coordinator) }
            }
        }
        .onChange(of: coordinator.pendingQuickAction) { _, newValue in
            // Switch to Lockbox, and clear any stale recovery path, only
            // when a Quick Action route is actually about to be presented —
            // never unconditionally on every launch/foreground. Previously
            // this ran on every `.active` transition regardless of whether
            // anything was pending, which threw the user back to the
            // Lockbox tab on any return to the app (for example, from
            // Messages after accepting a companion invite on the People
            // tab), and could undo People-tab routing from an opened
            // invite link. Every queued route remains navigation-only;
            // enforcement and recovery state are untouched here either way.
            guard newValue != nil else { return }
            selectedTab = 0
            lockboxPath = []
        }
    }

    @Environment(\.scenePhase) private var scenePhase
}

#Preview {
    ContentView()
}
