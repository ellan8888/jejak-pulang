import SwiftUI

@main
struct JejakPulangApp: App {
    @StateObject private var library = RouteLibrary()
    @StateObject private var recorder = LocationRecorder()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(library)
                .environmentObject(recorder)
        }
    }
}
