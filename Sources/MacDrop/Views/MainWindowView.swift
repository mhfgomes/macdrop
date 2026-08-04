import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MacDropStyle.accent)
                    Text("MacDrop")
                        .font(.title2.weight(.bold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 14)

                List(AppModel.SidebarSection.allCases, selection: $appModel.selectedSection) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .font(.body.weight(.medium))
                        .padding(.vertical, 4)
                        .tag(section)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
        } detail: {
            switch appModel.selectedSection {
            case .library: LibraryView()
            case .playlists: PlaylistsView()
            case .displays: DisplaysView()
            case .settings: SettingsView()
            }
        }
    }
}
