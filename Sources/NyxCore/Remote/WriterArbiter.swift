import Foundation

/// Who may type into a host's session, across however many clients have attached to it. Exists
/// apart from `AttachState` because the rule is about the *set* of attached clients -- who was
/// first, who is left when the writer goes -- not about any one client's own view.
public struct WriterArbiter: Equatable {
    /// Attachment order, oldest first. Doubles as the promotion queue: when the writer leaves, the
    /// device that has been attached the longest of those remaining is the fairest next writer --
    /// picking the most recent arrival instead would let a brand-new observer jump the queue.
    private var order: [String] = []
    private var writerID: String?

    public init() {}

    public var writer: String? { writerID }

    /// The first device to attach to a session becomes its writer; every one after is an observer
    /// until it takes control or the writer leaves.
    public mutating func attached(_ deviceID: String) -> AttachState.Role {
        order.append(deviceID)
        if writerID == nil {
            writerID = deviceID
            return .writer
        }
        return .observer
    }

    /// Removes a device. If it was not the writer, nobody else's role changes. If it was, the
    /// longest-attached remaining observer is promoted -- or nobody is, if it was attached alone.
    public mutating func detached(_ deviceID: String) -> [(deviceID: String, role: AttachState.Role)] {
        order.removeAll { $0 == deviceID }
        guard deviceID == writerID else { return [] }
        guard let next = order.first else {
            writerID = nil
            return []
        }
        writerID = next
        return [(next, .writer)]
    }

    /// `deviceID` presses "Take control": it becomes the writer, and whoever held the role is
    /// demoted to observer. A device already the writer taking control again is a no-op -- nothing
    /// changed, so nothing to report. A device that never attached is also a no-op: without this
    /// guard it would become writer while absent from `order`, so `detached` could never promote
    /// anyone once it left and a re-attach of the same id would silently duplicate it.
    public mutating func takeControl(_ deviceID: String) -> [(deviceID: String, role: AttachState.Role)] {
        guard order.contains(deviceID), deviceID != writerID else { return [] }
        var changes: [(deviceID: String, role: AttachState.Role)] = []
        if let previous = writerID { changes.append((previous, .observer)) }
        writerID = deviceID
        changes.append((deviceID, .writer))
        return changes
    }

    public func role(of deviceID: String) -> AttachState.Role? {
        guard order.contains(deviceID) else { return nil }
        return deviceID == writerID ? .writer : .observer
    }
}
