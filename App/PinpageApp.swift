import SwiftUI

@main
struct PinpageApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Pinpage") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
    }
}
