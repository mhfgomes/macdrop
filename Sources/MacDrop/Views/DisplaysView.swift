import MacDropCore
import SwiftData
import SwiftUI

struct DisplaysView: View {
    @EnvironmentObject private var appModel: AppModel
    @Query(sort: \Wallpaper.importedAt, order: .reverse) private var wallpapers: [Wallpaper]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @Query private var assignments: [DisplayAssignment]

    var body: some View {
        MacDropPage {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if appModel.displays.displays.isEmpty {
                        ContentUnavailableView("No Displays Found", systemImage: "display")
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 20)], spacing: 20) {
                            ForEach(appModel.displays.displays) { display in
                                displayCard(display)
                            }
                        }
                    }

                    let disconnected = assignments.filter { assignment in
                        !appModel.displays.displays.contains { $0.id == assignment.displayUUID }
                    }
                    if !disconnected.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            MacDropSectionTitle(title: "Saved Displays", systemImage: "display.trianglebadge.exclamationmark")
                            ForEach(Array(disconnected.enumerated()), id: \.element.id) { index, assignment in
                                HStack(spacing: 12) {
                                    Image(systemName: "display")
                                        .foregroundStyle(.secondary)
                                    Text("Display \(index + 1)")
                                        .fontWeight(.medium)
                                    Spacer()
                                    Button("Forget") {
                                        appModel.forgetAssignment(assignment)
                                    }
                                }
                                .padding(14)
                                .macDropCard()
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Displays")
        .toolbar {
            Button { appModel.reconcileDisplaysAndAssignments() } label: {
                Label("Refresh Displays", systemImage: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private func displayCard(_ display: DisplayDescriptor) -> some View {
        let assignment = assignments.first { $0.displayUUID == display.id }
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MacDropStyle.accent.opacity(0.16))
                Image(systemName: "display")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(MacDropStyle.accent)
            }
            .frame(height: 118)

            HStack(alignment: .firstTextBaseline) {
                Text(display.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Spacer()
                if display.isMain {
                    Text("Main")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }

            Picker("Wallpaper", selection: sourceBinding(displayID: display.id, assignment: assignment)) {
                if wallpapers.isEmpty && playlists.isEmpty {
                    Text("Add a wallpaper first").tag("")
                }
                if !wallpapers.isEmpty {
                    Section("Wallpapers") {
                        ForEach(wallpapers) { Text($0.name).tag("wallpaper:\($0.id.uuidString)") }
                    }
                }
                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { Text($0.name).tag("playlist:\($0.id.uuidString)") }
                    }
                }
            }
            .controlSize(.large)

            if let assignment {
                Picker("Sizing", selection: Binding(
                    get: { assignment.contentMode },
                    set: { assignment.contentMode = $0; saveAndApply(assignment) }
                )) {
                    Text("Fill Screen").tag(WallpaperContentMode.fill)
                    Text("Fit Screen").tag(WallpaperContentMode.fit)
                }
                .pickerStyle(.segmented)

                if case .playlist = assignment.source {
                    VStack(spacing: 12) {
                        HStack {
                            Label("Change", systemImage: "clock")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Change", selection: Binding(
                                get: { assignment.advanceMode },
                                set: { assignment.advanceMode = $0; saveAndApply(assignment) }
                            )) {
                                Text("Every").tag(PlaylistAdvanceMode.interval)
                                Text("On End").tag(PlaylistAdvanceMode.videoEnd)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                        }

                        if assignment.advanceMode == .interval {
                            HStack {
                                Text("Interval")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Stepper("\(assignment.rotationMinutes) min", value: Binding(
                                    get: { assignment.rotationMinutes },
                                    set: { assignment.rotationMinutes = min(1_440, max(1, $0)); saveAndApply(assignment) }
                                ), in: 1...1_440)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button { appModel.previous(on: display.id) } label: {
                        Image(systemName: "backward.fill").frame(width: 26, height: 26)
                    }
                    Button { appModel.toggleManualPause() } label: {
                        Image(systemName: appModel.playback.globallyPaused ? "play.fill" : "pause.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { appModel.next(on: display.id) } label: {
                        Image(systemName: "forward.fill").frame(width: 26, height: 26)
                    }
                    Spacer()
                    if let current = currentWallpaper(assignment) {
                        Text(current.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .macDropCard()
    }

    private func sourceBinding(displayID: String, assignment: DisplayAssignment?) -> Binding<String> {
        Binding {
            guard let assignment else { return "" }
            switch assignment.source {
            case .wallpaper(let id): return "wallpaper:\(id.uuidString)"
            case .playlist(let id): return "playlist:\(id.uuidString)"
            }
        } set: { value in
            let pieces = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let id = UUID(uuidString: pieces[1]) else { return }
            if pieces[0] == "wallpaper", let wallpaper = wallpapers.first(where: { $0.id == id }) {
                appModel.assign(wallpaper, to: displayID)
            } else if let playlist = playlists.first(where: { $0.id == id }) {
                appModel.assign(playlist, to: displayID)
            }
        }
    }

    private func currentWallpaper(_ assignment: DisplayAssignment) -> Wallpaper? {
        guard let id = assignment.lastWallpaperID else { return nil }
        return wallpapers.first { $0.id == id }
    }

    private func saveAndApply(_ assignment: DisplayAssignment) {
        try? appModel.context.save()
        appModel.reconcileDisplaysAndAssignments()
    }
}
