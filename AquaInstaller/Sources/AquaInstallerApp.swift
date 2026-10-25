import SwiftUI

@main
struct AquaInstallerApp: App {
    @StateObject private var model = AquaInstallerModel()

    var body: some Scene {
        WindowGroup("Aqua Installer") {
            AquaInstallerView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
