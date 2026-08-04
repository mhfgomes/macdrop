import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginController: LaunchAtLoginControlling {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if enabled {
            switch status {
            case .enabled:
                return
            case .requiresApproval:
                throw LaunchAtLoginError.requiresApproval
            case .notRegistered:
                try SMAppService.mainApp.register()
            case .notFound:
                throw LaunchAtLoginError.unavailable
            @unknown default:
                throw LaunchAtLoginError.unavailable
            }
        } else {
            switch status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            case .notRegistered, .notFound:
                return
            @unknown default:
                return
            }
        }
    }
}

public enum LaunchAtLoginError: LocalizedError {
    case requiresApproval
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .requiresApproval:
            "Approve MacDrop in System Settings → General → Login Items."
        case .unavailable:
            "Launch at Login is unavailable for this copy of MacDrop."
        }
    }
}
