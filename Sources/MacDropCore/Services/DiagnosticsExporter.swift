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
            "displays": displays.enumerated().map { index, display in [
                "id": "display-\(index + 1)",
                "width": Int(display.frame.width),
                "height": Int(display.frame.height),
                "scale": display.backingScaleFactor,
                "main": display.isMain
            ] },
            "lockScreen": ["state": lockHealth.state.rawValue, "message": lockHealth.message]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)

        let logDestination = directory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDestination, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: paths.logs.path) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let enumerator = FileManager.default.enumerator(at: paths.logs, includingPropertiesForKeys: nil)
            while let item = enumerator?.nextObject() as? URL {
                guard !item.hasDirectoryPath else { continue }
                let relative = item.path.replacingOccurrences(of: paths.logs.path + "/", with: "")
                let destination = logDestination.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let raw = (try? String(contentsOf: item, encoding: .utf8)) ?? ""
                let redacted = raw
                    .replacingOccurrences(of: home, with: "~")
                    .replacingOccurrences(
                        of: #"/Users/[^/\s]+"#,
                        with: "~",
                        options: .regularExpression
                    )
                try redacted.write(to: destination, atomically: true, encoding: .utf8)
            }
        }

        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDrop-Diagnostics-\(Self.timestamp).zip")
        try? FileManager.default.removeItem(at: archive)
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

