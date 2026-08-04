import AppKit
import MacDropCore
import SwiftData
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @Query(sort: \Wallpaper.importedAt, order: .reverse) private var wallpapers: [Wallpaper]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @State private var search = ""
    @State private var pendingLockWallpaper: Wallpaper?
    @State private var pendingDeleteWallpaper: Wallpaper?
    @State private var pendingRenameWallpaper: Wallpaper?
    @State private var renameText = ""
    @State private var dropTargeted = false

    private let itemSpacing: CGFloat = 14.2
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 230), spacing: itemSpacing),
            count: 3
        )
    }
    private var filtered: [Wallpaper] {
        search.isEmpty ? wallpapers : wallpapers.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        MacDropPage {
            Group {
                if wallpapers.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 48, weight: .medium))
                            .foregroundStyle(MacDropStyle.accent)
                        VStack(spacing: 6) {
                            Text("Add your first wallpaper")
                                .font(.title2.weight(.bold))
                            Text("Choose a video from your Mac.")
                                .foregroundStyle(.secondary)
                        }
                        Button("Choose Video…") { appModel.openImportPanel() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: itemSpacing) {
                            ForEach(filtered) { wallpaper in
                                card(wallpaper)
                            }
                        }
                        .padding(24)
                    }
                }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $search, prompt: "Search wallpapers")
        .toolbar {
            if appModel.isImporting {
                ToolbarItem {
                    ProgressView()
                        .controlSize(.small)
                        .help("Adding videos to the library")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { appModel.openImportPanel() } label: { Label("Add Wallpaper", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.accentColor.opacity(0.09))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [9]))
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
            if appModel.isLockScreenBusy {
                ZStack {
                    Color.black.opacity(0.28)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(appModel.lockScreenProgressMessage ?? "Updating the lock screen…")
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .padding(24)
                    .macDropCard()
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await appModel.importVideos(urls) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .alert("Use on Lock Screen?", isPresented: Binding(
            get: { pendingLockWallpaper != nil }, set: { if !$0 { pendingLockWallpaper = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingLockWallpaper = nil }
            Button("Enable") {
                guard let wallpaper = pendingLockWallpaper else { return }
                pendingLockWallpaper = nil
                Task { await appModel.prepareAndInstallLockScreen(wallpaper) }
            }
        } message: {
            Text("This wallpaper will appear when your Mac is locked. You can undo it anytime in Settings.")
        }
        .alert("Delete Wallpaper?", isPresented: Binding(
            get: { pendingDeleteWallpaper != nil }, set: { if !$0 { pendingDeleteWallpaper = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeleteWallpaper = nil }
            Button("Move to Trash", role: .destructive) {
                guard let wallpaper = pendingDeleteWallpaper else { return }
                pendingDeleteWallpaper = nil
                Task { await appModel.deleteWallpaper(wallpaper) }
            }
        } message: {
            Text("This also removes it from playlists and displays.")
        }
        .alert("Rename Wallpaper", isPresented: Binding(
            get: { pendingRenameWallpaper != nil }, set: { if !$0 { pendingRenameWallpaper = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { pendingRenameWallpaper = nil }
            Button("Rename") {
                guard let wallpaper = pendingRenameWallpaper else { return }
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { wallpaper.name = trimmed; try? appModel.context.save() }
                pendingRenameWallpaper = nil
            }
        }
    }

    @ViewBuilder
    private func card(_ wallpaper: Wallpaper) -> some View {
        let optimizing = isOptimizing(wallpaper)
        VStack(alignment: .leading, spacing: 0) {
            WallpaperThumbnail(wallpaper: wallpaper, height: 156)
                .saturation(optimizing ? 0.15 : 1)
                .opacity(optimizing ? 0.52 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if !optimizing {
                        Text(duration(wallpaper.duration))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.62), in: Capsule())
                            .padding(9)
                    }
                }
                .overlay(alignment: .bottom) {
                    if optimizing {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(optimizationLabel(wallpaper))
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                if let eta = appModel.optimizationETA[wallpaper.id] {
                                    Text("\(formattedETA(eta)) left")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.72))
                                }
                                if let progress = appModel.optimizationProgress[wallpaper.id] {
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption2.monospacedDigit())
                                }
                                Button {
                                    appModel.cancelOptimization(wallpaper)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.body)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white.opacity(0.85))
                                .help("Cancel optimization")
                            }
                            ProgressView(value: appModel.optimizationProgress[wallpaper.id] ?? 0)
                                .progressViewStyle(.linear)
                                .tint(.accentColor)
                        }
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(9)
                    } else if case .failed = wallpaper.lockAssetStatus {
                        Label("Optimization failed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.orange.opacity(0.92), in: Capsule())
                            .padding(9)
                    } else if case .cancelled = wallpaper.lockAssetStatus {
                        Label("Optimization canceled", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.secondary.opacity(0.88), in: Capsule())
                            .padding(9)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(qualityLabel(wallpaper))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .macDropCard()
        .contextMenu {
            wallpaperActions(wallpaper)
        }
    }

    @ViewBuilder
    private func wallpaperActions(_ wallpaper: Wallpaper) -> some View {
            Menu("Set on Display") {
                ForEach(appModel.displays.displays) { display in
                    Button(display.name) { appModel.assign(wallpaper, to: display.id) }
                }
            }
            Menu("Add to Playlist") {
                if playlists.isEmpty { Text("No playlists") }
                ForEach(playlists) { playlist in
                    Button(playlist.name) { appModel.add(wallpaper, to: playlist) }
                }
            }
            Button("Use on Lock Screen") { pendingLockWallpaper = wallpaper }
                .disabled(appModel.isLockScreenBusy || isOptimizing(wallpaper))
            if case .failed = wallpaper.lockAssetStatus {
                Button("Retry Optimization", systemImage: "arrow.clockwise") {
                    appModel.retryOptimization(wallpaper)
                }
            }
            if case .cancelled = wallpaper.lockAssetStatus {
                Button("Resume Optimization", systemImage: "play.fill") {
                    appModel.retryOptimization(wallpaper)
                }
            }
            Button("Rename") { renameText = wallpaper.name; pendingRenameWallpaper = wallpaper }
            Divider()
            Button("Delete", role: .destructive) { pendingDeleteWallpaper = wallpaper }
                .disabled(isOptimizing(wallpaper))
    }

    private func qualityLabel(_ wallpaper: Wallpaper) -> String {
        if wallpaper.pixelWidth >= 3_840 || wallpaper.pixelHeight >= 2_160 { return "4K video" }
        if wallpaper.pixelWidth >= 1_920 || wallpaper.pixelHeight >= 1_080 { return "HD video" }
        return "Video wallpaper"
    }

    private func isOptimizing(_ wallpaper: Wallpaper) -> Bool {
        if appModel.queuedOptimizationIDs.contains(wallpaper.id) { return true }
        if appModel.optimizationProgress[wallpaper.id] != nil { return true }
        if case .preparing = wallpaper.lockAssetStatus { return true }
        return false
    }

    private func optimizationLabel(_ wallpaper: Wallpaper) -> String {
        appModel.queuedOptimizationIDs.contains(wallpaper.id) ? "Waiting to optimize" : "Optimizing video"
    }

    private func formattedETA(_ seconds: TimeInterval) -> String {
        let rounded = max(1, Int(seconds.rounded()))
        if rounded < 60 { return "\(rounded)s" }
        let minutes = rounded / 60
        if minutes < 60 { return "\(minutes)m \(rounded % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
