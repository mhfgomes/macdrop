import MacDropCore
import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Query(sort: \Wallpaper.importedAt, order: .reverse) private var wallpapers: [Wallpaper]
    @State private var confirmRestore = false
    @State private var confirmReset = false
    @State private var confirmUninstall = false
    @State private var uninstallReady = false

    var body: some View {
        MacDropPage {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    settingsSection("General", systemImage: "gearshape.fill") {
                        settingToggle(
                            "Open at Login",
                            systemImage: "power",
                            isOn: Binding(
                                get: { appModel.preferences.launchAtLogin },
                                set: { appModel.setLaunchAtLogin($0) }
                            )
                        )
                    }

                    settingsSection("Playback", systemImage: "play.circle.fill") {
                        VStack(spacing: 0) {
                            preferenceToggle("Pause when hidden", systemImage: "eye.slash", keyPath: \AppPreferences.pauseWhenObscured)
                            rowDivider
                            preferenceToggle("Pause for fullscreen apps", systemImage: "rectangle.inset.filled", keyPath: \AppPreferences.pauseForFullscreenApps)
                            rowDivider
                            preferenceToggle("Save power on battery", systemImage: "battery.50percent", keyPath: \AppPreferences.reduceQualityOnBattery)
                            rowDivider
                            preferenceToggle("Pause on battery", systemImage: "battery.25percent", keyPath: \AppPreferences.pauseOnBattery)
                            rowDivider
                            preferenceToggle("Pause when Mac gets hot", systemImage: "thermometer.high", keyPath: \AppPreferences.pauseAtSeriousThermalState)
                        }
                    }

                    settingsSection("Lock Screen", systemImage: "lock.fill") {
                        VStack(spacing: 16) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(healthColor.opacity(0.14))
                                    Image(systemName: healthIcon)
                                        .foregroundStyle(healthColor)
                                }
                                .frame(width: 42, height: 42)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lockStatusTitle)
                                        .font(.headline)
                                    if let wallpaper = pinnedWallpaper {
                                        Text(wallpaper.name)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if appModel.isLockScreenBusy {
                                    ProgressView().controlSize(.small)
                                }
                            }

                            HStack {
                                Button("Wallpaper Settings") { appModel.openWallpaperSettings() }
                                Spacer()
                                Button("Restore", role: .destructive) { confirmRestore = true }
                                    .disabled(appModel.lockHealth.state == .disabled || appModel.isLockScreenBusy)
                            }
                        }
                        .padding(16)
                    }

                    settingsSection("About", systemImage: "sparkles.rectangle.stack.fill") {
                        HStack(spacing: 14) {
                            Image(systemName: "sparkles.rectangle.stack.fill")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(MacDropStyle.accent)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("MacDrop")
                                    .font(.headline)
                                Text("Version \(version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let releaseURL {
                                Link("Releases", destination: releaseURL)
                            }
                        }
                        .padding(16)
                    }

                    settingsSection("Danger Zone", systemImage: "exclamationmark.triangle.fill") {
                        VStack(spacing: 0) {
                            destructiveRow(
                                "Reset MacDrop",
                                systemImage: "arrow.counterclockwise",
                                buttonTitle: "Reset…"
                            ) { confirmReset = true }
                            rowDivider
                            destructiveRow(
                                "Uninstall MacDrop",
                                systemImage: "trash.fill",
                                buttonTitle: "Uninstall…"
                            ) { confirmUninstall = true }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Settings")
        .alert("Restore Lock Screen?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) { Task { await appModel.restoreLockScreen() } }
        } message: {
            Text("Your previous lock screen will be restored.")
        }
        .alert("Reset MacDrop?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Everything", role: .destructive) {
                Task { await appModel.resetApplicationData() }
            }
        } message: {
            Text("This restores your previous lock screen and removes all imported wallpapers, playlists, display assignments, and settings. Managed videos are moved to Trash.")
        }
        .alert("Uninstall MacDrop?", isPresented: $confirmUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Prepare Uninstall", role: .destructive) {
                Task {
                    if await appModel.prepareForManualUninstall() {
                        uninstallReady = true
                    }
                }
            }
        } message: {
            Text("This restores your previous lock screen and clears MacDrop’s data. The application file will not be removed.")
        }
        .alert("Ready to Remove MacDrop", isPresented: $uninstallReady) {
            Button("Close MacDrop") { appModel.finishManualUninstall() }
        } message: {
            Text("MacDrop has cleared its data. To finish uninstalling, move MacDrop.app from Applications to Trash after the app closes.")
        }
    }

    private var pinnedWallpaper: Wallpaper? {
        guard let id = appModel.preferences.lockScreenWallpaperID else { return nil }
        return wallpapers.first { $0.id == id }
    }

    private var lockStatusTitle: String {
        switch appModel.lockHealth.state {
        case .disabled: "Not set"
        case .healthy: "Lock screen is active"
        case .degraded: "Needs attention"
        case .incompatible: "Unavailable"
        }
    }

    private var healthIcon: String {
        switch appModel.lockHealth.state {
        case .disabled: "lock.open.fill"
        case .healthy: "checkmark"
        case .degraded: "exclamationmark"
        case .incompatible: "xmark"
        }
    }

    private var healthColor: Color {
        switch appModel.lockHealth.state {
        case .disabled: .secondary
        case .healthy: .green
        case .degraded: .orange
        case .incompatible: .red
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var releaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MACDROP_RELEASES_URL") as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return URL(string: value)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            MacDropSectionTitle(title: title, systemImage: systemImage)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .macDropCard()
        }
    }

    @ViewBuilder
    private func preferenceToggle(
        _ title: String,
        systemImage: String,
        keyPath: ReferenceWritableKeyPath<AppPreferences, Bool>
    ) -> some View {
        settingToggle(title, systemImage: systemImage, isOn: Binding(
            get: { appModel.preferences[keyPath: keyPath] },
            set: { appModel.preferences[keyPath: keyPath] = $0; appModel.persistPreferences() }
        ))
    }

    private func settingToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.accentColor)
        }
        .padding(15)
    }

    private func destructiveRow(
        _ title: String,
        systemImage: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .foregroundStyle(.red)
                .frame(width: 22)
            Text(title)
            Spacer()
            if appModel.isDestructiveOperationBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(buttonTitle, role: .destructive, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(15)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 50)
    }
}
