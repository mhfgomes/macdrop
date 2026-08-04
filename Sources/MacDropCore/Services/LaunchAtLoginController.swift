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
            default:
                try SMAppService.mainApp.register()
            }
        } else {
            switch status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            default:
                return
            }
        }
    }
}

public enum LaunchAtLoginError: LocalizedError {
    case requiresApproval

    public var errorDescription: String? {
        switch self {
        case .requiresApproval:
            "MacDrop is waiting for Login Items approval in System Settings."
        }
    }
}
