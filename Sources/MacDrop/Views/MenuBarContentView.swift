import AppKit
import MacDropCore
import SwiftData
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Wallpaper.importedAt, order: .reverse) private var wallpapers: [Wallpaper]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @Query private var assignments: [DisplayAssignment]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(MacDropStyle.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacDrop").font(.headline)
                    Text(appModel.playback.globallyPaused ? "Paused" : "Playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { appModel.toggleManualPause() } label: {
                    Image(systemName: appModel.playback.globallyPaused ? "play.fill" : "pause.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .help(appModel.playback.globallyPaused ? "Resume" : "Pause")
            }

            Divider()
            if appModel.displays.displays.isEmpty {
                Text("No displays found").foregroundStyle(.secondary)
            }
            ForEach(appModel.displays.displays) { display in
                let assignment = assignments.first { $0.displayUUID == display.id }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Image(systemName: "display").foregroundStyle(.secondary)
                        Text(display.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(currentName(assignment)).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Button { appModel.previous(on: display.id) } label: { Image(systemName: "backward.fill") }
                        Button { appModel.next(on: display.id) } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.borderless)
                    Menu("Choose Wallpaper") {
                        Section("Wallpapers") {
                            ForEach(wallpapers) { wallpaper in Button(wallpaper.name) { appModel.assign(wallpaper, to: display.id) } }
                        }
                        Section("Playlists") {
                            ForEach(playlists) { playlist in Button(playlist.name) { appModel.assign(playlist, to: display.id) } }
                        }
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                }
                if display.id != appModel.displays.displays.last?.id { Divider() }
            }

            HStack(spacing: 10) {
                Button("Open MacDrop") { appModel.showMainWindow(openWindow: openWindow) }
                    .buttonStyle(.borderedProminent)
                Button { appModel.showSettings(openWindow: openWindow) } label: {
                    Image(systemName: "gearshape")
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .disabled(appModel.isLockScreenBusy || appModel.isDestructiveOperationBusy)
                .help("Quit MacDrop")
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func currentName(_ assignment: DisplayAssignment?) -> String {
        guard let assignment else { return "Not configured" }
        switch assignment.source {
        case .wallpaper(let id): return wallpapers.first(where: { $0.id == id })?.name ?? "Missing wallpaper"
        case .playlist(let id): return playlists.first(where: { $0.id == id })?.name ?? "Missing playlist"
        }
    }
}
