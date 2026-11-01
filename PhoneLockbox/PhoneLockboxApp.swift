import SwiftUI

@main
struct PhoneLockboxApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
