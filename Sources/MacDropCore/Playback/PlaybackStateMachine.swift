import Foundation

public struct PlaybackStateMachine: Equatable, Sendable {
    public private(set) var reasons: Set<PlaybackPauseReason> = []

    public init() {}

    public var isPaused: Bool { !reasons.isEmpty }

    public mutating func set(_ reason: PlaybackPauseReason, active: Bool) {
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}

