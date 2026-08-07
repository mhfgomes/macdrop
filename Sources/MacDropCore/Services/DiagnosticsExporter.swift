import Foundation

public struct DiagnosticsExporter: Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths = AppPaths()) {
        self.paths = paths
    }

    public func export(
        appVersion: String,
        displays: [DisplayDescriptor],
        lockHealth: LockScreenHealth
    ) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDrop-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload: [String: Any] = [
            "appVersion": appVersion,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": Self.architecture,
            "displayCount": displays.count,
            "displays": displays.map { [
                "id": String($0.id.suffix(8)),
                "name": $0.name,
                "width": Int($0.frame.width),
                "height": Int($0.frame.height),
                "scale": $0.backingScaleFactor,
                "main": $0.isMain
            ] },
            "lockScreen": ["state": lockHealth.state.rawValue, "message": lockHealth.message]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)

        let logDestination = directory.appendingPathComponent("logs", isDirectory: true)
        if FileManager.default.fileExists(atPath: paths.logs.path) {
            try? FileManager.default.copyItem(at: paths.logs, to: logDestination)
        }

        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDrop-Diagnostics-\(Self.timestamp)-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", directory.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return archive
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

