import Foundation

public final class PlaylistScheduler: PlaylistScheduling {
    public init() {}

    public func nextID(in ids: [UUID], current: UUID?, order: PlaylistOrder) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard ids.count > 1 else { return ids[0] }
        switch order {
        case .sequential:
            guard let current, let index = ids.firstIndex(of: current) else { return ids[0] }
            return ids[(index + 1) % ids.count]
        case .shuffle:
            let candidates = ids.filter { $0 != current }
            return candidates.randomElement()
        }
    }

    public func previousID(in ids: [UUID], current: UUID?) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids[0] }
        return ids[(index - 1 + ids.count) % ids.count]
    }
}

