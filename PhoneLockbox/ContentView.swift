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
            // A `phone-lockbox-companion://i/<token>` link (shared from the
            // People tab) routes to People, which looks the invite up and
            // shows "‹Name› invited you" with Accept / Not now. Opening it
            // never accepts anything by itself.
            if companion.handleIncomingCompanionLink(url) {
                selectedTab = 1
                return
            }
            selectedTab = 0
            lockboxPath = []
            coordinator.handleQuickActionURL(url)
        }
        .task {
            // Set once, before the first `processPendingQuickActionRoute()`
            // call below: switches to Lockbox and clears any stale recovery
            // path, but only from inside the coordinator, strictly before a
            // route is actually published as pending — see the doc comment
            // on `coordinator.onWillPresentQuickAction`. This is what
            // replaced an earlier `onChange(of: coordinator.pendingQuickAction)`
            // here (review P1): that ran reactively, racing
            // `LockboxTabView`'s own `onChange` of the same value with
            // undefined ordering, which could append `.recovery` and then
            // immediately clear it (or clear a path it hadn't appended to
            // yet), wedging `pendingQuickAction` since `RecoveryView` would
            // never actually appear to acknowledge/settle it.
            coordinator.onWillPresentQuickAction = {
                selectedTab = 0
                lockboxPath = []
            }
            coordinator.refreshAuthorization()
            coordinator.processPendingQuickActionRoute()
            #if os(iOS)
            // Wake-up pushes (R5 slice P4): the signed inbox is always the
            // source of truth, so a push only triggers a refresh. Tapping the
            // banner also opens People. Anything that arrived before this
            // handler existed (a cold-launch tap) is delivered on attach.
            PushWakeBridge.shared.peopleTabIsSelected = { selectedTab == 1 }
            PushWakeBridge.shared.wakeHandler = { _, opened in
                if opened { selectedTab = 1 }
                Task { await companion.handlePushWake() }
            }
            #endif
            await companion.pushForegroundTick()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.refreshAuthorization()
                // Scene reactivation is an explicit additional retry trigger
                // for the durable Quick Action queue (docs/quick-actions.md),
                // independent of whether anything is actually pending — this
                // call must run every time. It does not, by itself, switch
                // tabs or clear the Lockbox nav path; `onWillPresentQuickAction`
                // (set in `.task` above) does that only if this call actually
                // ends up presenting something.
                coordinator.processPendingQuickActionRoute()
                // R5 Slice B2c review, P2-4: finish an interrupted friend
                // release on every foreground, not only from the People tab.
                Task { await companion.replayPendingFriendRelease(coordinator: coordinator) }
                Task { await companion.pushForegroundTick() }
                // Back from sharing the invite link: now is the moment to ask.
                companion.invitePromptReturnPoint()
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
}

#Preview {
    ContentView()
}
