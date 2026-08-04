import MacDropCore
import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @Query(sort: \Wallpaper.importedAt, order: .reverse) private var wallpapers: [Wallpaper]
    @State private var selectedID: UUID?
    @State private var pendingDelete: Playlist?
    @State private var pendingRename: Playlist?
    @State private var showingCreatePrompt = false
    @State private var playlistName = ""

    private var selected: Playlist? { playlists.first { $0.id == selectedID } }

    var body: some View {
        MacDropPage {
            HStack(spacing: 0) {
                playlistSidebar
                    .frame(width: 245)

                Divider()

                if let playlist = selected {
                    playlistDetail(playlist)
                } else {
                    emptyDetail
                }
            }
        }
        .navigationTitle("Playlists")
        .onAppear { if selectedID == nil { selectedID = playlists.first?.id } }
        .onChange(of: playlists.count) { _, _ in
            if selected == nil { selectedID = playlists.first?.id }
        }
        .alert("New Playlist", isPresented: $showingCreatePrompt) {
            TextField("Playlist name", text: $playlistName)
            Button("Cancel", role: .cancel) { playlistName = "" }
            Button("Create") {
                let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                selectedID = appModel.createPlaylist(name: name).id
                playlistName = ""
            }
            .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } }
        )) {
            TextField("Playlist name", text: $playlistName)
            Button("Cancel", role: .cancel) {
                pendingRename = nil
                playlistName = ""
            }
            Button("Rename") {
                let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let playlist = pendingRename, !name.isEmpty else { return }
                playlist.name = name
                try? appModel.context.save()
                pendingRename = nil
                playlistName = ""
            }
            .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete Playlist?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                guard let playlist = pendingDelete else { return }
                pendingDelete = nil
                appModel.deletePlaylist(playlist)
                selectedID = playlists.first?.id
            }
        } message: {
            Text("Displays using it will switch to another wallpaper.")
        }
    }

    private var playlistSidebar: some View {
        VStack(spacing: 12) {
            Button {
                beginCreatingPlaylist()
            } label: {
                Label("New Playlist", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 14)
            .padding(.top, 16)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(playlists) { playlist in
                        Button {
                            selectedID = playlist.id
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "rectangle.stack.fill")
                                    .foregroundStyle(selectedID == playlist.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text("\(playlist.entries.count) \(playlist.entries.count == 1 ? "wallpaper" : "wallpapers")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .background(
                                selectedID == playlist.id ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename Playlist", systemImage: "pencil") {
                                beginRenaming(playlist)
                            }
                            Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                                pendingDelete = playlist
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .background(.ultraThinMaterial)
    }

    private var emptyDetail: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Create a playlist")
                .font(.title2.weight(.bold))
            Button("New Playlist") { beginCreatingPlaylist() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func playlistDetail(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Text(playlist.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)

                Menu {
                    ForEach(availableWallpapers(for: playlist)) { wallpaper in
                        Button(wallpaper.name) { appModel.add(wallpaper, to: playlist) }
                    }
                    if availableWallpapers(for: playlist).isEmpty {
                        Text("No wallpapers available")
                    }
                } label: {
                    Label("Add Wallpaper", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    Button("Rename Playlist", systemImage: "pencil") { beginRenaming(playlist) }
                    Button("Delete Playlist", role: .destructive) { pendingDelete = playlist }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            Picker("Playback order", selection: Binding(
                get: { playlist.playbackOrder },
                set: { playlist.playbackOrder = $0; try? appModel.context.save() }
            )) {
                Label("In Order", systemImage: "arrow.right").tag(PlaylistOrder.sequential)
                Label("Shuffle", systemImage: "shuffle").tag(PlaylistOrder.shuffle)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            List {
                ForEach(playlist.orderedEntries) { entry in
                    if let wallpaper = wallpapers.first(where: { $0.id == entry.wallpaperID }) {
                        HStack(spacing: 14) {
                            WallpaperThumbnail(wallpaper: wallpaper, height: 62)
                                .frame(width: 106)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text(wallpaper.name)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Button(role: .destructive) { appModel.remove(entry, from: playlist) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Color.clear)
                    }
                }
                .onMove { appModel.moveEntries(in: playlist, from: $0, to: $1) }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if playlist.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("Add wallpapers to get started")
                            .font(.headline)
                    }
                }
            }
            .macDropCard()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func availableWallpapers(for playlist: Playlist) -> [Wallpaper] {
        wallpapers.filter { wallpaper in
            !playlist.entries.contains { $0.wallpaperID == wallpaper.id }
        }
    }

    private func beginCreatingPlaylist() {
        playlistName = ""
        showingCreatePrompt = true
    }

    private func beginRenaming(_ playlist: Playlist) {
        playlistName = playlist.name
        pendingRename = playlist
    }
}
