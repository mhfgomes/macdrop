import CoreGraphics
import Foundation

public struct DisplayDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let frame: CGRect
    public let isMain: Bool
    public let backingScaleFactor: CGFloat

    public init(id: String, name: String, frame: CGRect, isMain: Bool, backingScaleFactor: CGFloat) {
        self.id = id
        self.name = name
        self.frame = frame
        self.isMain = isMain
        self.backingScaleFactor = backingScaleFactor
    }
}

