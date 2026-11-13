import SwiftUI
import AppKit

let VERSION = 1

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        Task { @MainActor in Store.shared.startServer() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { Store.shared.rack.stop() }
    }
}

@main
struct PluginAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared
    var body: some Scene {
        WindowGroup("Plugin Assistant (Mantra)") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 520, idealWidth: 620, maxWidth: .infinity,
                       minHeight: 520, idealHeight: 760, maxHeight: .infinity)
        }
        .defaultSize(width: 620, height: 760)
        .windowResizability(.contentMinSize)
    }
}
