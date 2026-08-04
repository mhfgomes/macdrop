import AppKit
import CoreGraphics
import Foundation

@MainActor
public final class DisplayDiscovery: ObservableObject, DisplayDiscovering {
    @Published public private(set) var displays: [DisplayDescriptor] = []

    public init() {
        refresh()
    }

    public func refresh() {
        displays = NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let displayID = CGDirectDisplayID(number?.uint32Value ?? 0)
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
                ?? "display-\(displayID)"
            return DisplayDescriptor(
                id: uuid,
                name: screen.localizedName,
                frame: screen.frame,
                isMain: screen == NSScreen.main,
                backingScaleFactor: screen.backingScaleFactor
            )
        }
    }
}
