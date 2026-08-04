import AppKit
import Combine
import MacDropCore
import SwiftData
import SwiftUI

@main
struct MacDropApp: App {
    @NSApplicationDelegateAdaptor(MacDropAppDelegate.self) private var appDelegate
    @StateObject private var launcher = AppLauncher()

    var body: some Scene {
        WindowGroup("MacDrop", id: "main") {
            switch launcher.state {
            case .ready(let resources):
                MainWindowView()
                    .environmentObject(resources.appModel)
                    .frame(minWidth: 900, minHeight: 600)
                    .alert("MacDrop", isPresented: Binding(
                        get: { resources.appModel.presentedError != nil },
                        set: { if !$0 { resources.appModel.presentedError = nil } }
                    )) {
                        Button("OK", role: .cancel) { resources.appModel.presentedError = nil }
                    } message: {
                        Text(resources.appModel.presentedError ?? "")
                    }
                    .modelContainer(resources.container)
            case .failed(let message):
                StartupFailureView(
                    message: message,
                    retry: launcher.retry,
                    resetDatabase: launcher.resetDatabase
                )
            }
        }
        .defaultSize(width: 1_080, height: 720)

        MenuBarExtra(
            "MacDrop",
            systemImage: "sparkles.rectangle.stack.fill",
            isInserted: Binding(
                get: { launcher.state.isReady },
                set: { _ in }
            )
        ) {
            if case .ready(let resources) = launcher.state {
                MenuBarContentView()
                    .environmentObject(resources.appModel)
                    .modelContainer(resources.container)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class AppLauncher: ObservableObject {
    @Published private(set) var state: LaunchState

    private let paths: AppPaths

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        self.state = Self.launch(paths: paths)
    }

    func retry() {
        state = Self.launch(paths: paths)
    }

    func resetDatabase() {
        do {
            let manager = FileManager.default
            for url in databaseFiles where manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            retry()
        } catch {
            state = .failed("MacDrop could not reset its local database: \(error.localizedDescription)")
        }
    }

    private var databaseFiles: [URL] {
        let store = paths.databaseStore
        return [
            store,
            URL(fileURLWithPath: store.path + "-shm"),
            URL(fileURLWithPath: store.path + "-wal"),
            URL(fileURLWithPath: store.path + "-journal")
        ]
    }

    private static func launch(paths: AppPaths) -> LaunchState {
        let container: ModelContainer
        do {
            try paths.prepare()
            let schema = Schema(MacDropSchema.models)
            let configuration = ModelConfiguration(
                "MacDrop",
                schema: schema,
                url: paths.databaseStore
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            return .failed("MacDrop could not open its local database: \(error.localizedDescription)")
        }

        do {
            return .ready(AppResources(
                container: container,
                appModel: try AppModel(container: container)
            ))
        } catch {
            return .failed("MacDrop could not initialize its library: \(error.localizedDescription)")
        }
    }
}

private enum LaunchState {
    case ready(AppResources)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

private struct AppResources {
    let container: ModelContainer
    let appModel: AppModel
}

private struct StartupFailureView: View {
    let message: String
    let retry: () -> Void
    let resetDatabase: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("MacDrop Couldn’t Start")
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 560)
            HStack {
                Button("Reset Local Database", role: .destructive, action: resetDatabase)
                Button("Retry", action: retry)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(minWidth: 640, minHeight: 360)
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
