import SwiftUI

@main
struct GalleryApp: App {
    @StateObject private var model = GalleryModel.fromLaunchArguments()

    var body: some Scene {
        WindowGroup {
            GalleryRootView(model: model)
        }
    }
}
