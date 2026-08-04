import AppKit
import MacDropCore
import SwiftData
import SwiftUI

@main
struct MacDropApp: App {
    @NSApplicationDelegateAdaptor(MacDropAppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @StateObject private var appModel: AppModel

    init() {
        do {
            let paths = AppPaths()
            try paths.prepare()
            let schema = Schema(MacDropSchema.models)
            let configuration = ModelConfiguration(
                "MacDrop",
                schema: schema,
                url: paths.root.appendingPathComponent("MacDrop.store")
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            self.container = container
            _appModel = StateObject(wrappedValue: AppModel(container: container))
        } catch {
            fatalError("MacDrop could not open its local database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("MacDrop", id: "main") {
            MainWindowView()
                .environmentObject(appModel)
                .frame(minWidth: 900, minHeight: 600)
                .alert("MacDrop", isPresented: Binding(
                    get: { appModel.presentedError != nil },
                    set: { if !$0 { appModel.presentedError = nil } }
                )) {
                    Button("OK", role: .cancel) { appModel.presentedError = nil }
                } message: {
                    Text(appModel.presentedError ?? "")
                }
        }
        .defaultSize(width: 1_080, height: 720)
        .modelContainer(container)

        MenuBarExtra("MacDrop", systemImage: "sparkles.rectangle.stack.fill") {
            MenuBarContentView()
                .environmentObject(appModel)
                .modelContainer(container)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MacDropAppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let visibleAppWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
                if visibleAppWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}
