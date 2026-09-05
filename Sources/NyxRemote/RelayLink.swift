import Foundation
import NyxCore

/// The half of `RelayConnection` the host and client orchestrators actually use: put something on
/// the wire, and know which device this end is.
///
/// It exists so `RemoteHost` and `RemoteClient` can be tested at all. Foundation has no in-process
/// WebSocket server, so a test that insisted on a real `RelayConnection` would either need the Go
/// relay running (an integration test, not a unit one) or would leave the two orchestrators -- the
/// pieces that decide who may type and what a client sees at attach -- with no tests whatsoever.
/// Behind this protocol both sides run their real crypto against each other with the socket
/// replaced by a function call.
///
/// Delivery in the other direction is not part of it: the connection pushes what it receives to a
/// `RelayConnectionDelegate`, and the app hands those to `handle(_:)`. One protocol for both
/// directions would have made every test implement callbacks it does not use.
public protocol RelayLink: AnyObject {
    func send(_ m: RemoteMessage)
    func send(_ f: BinaryFrame)
    var deviceID: String { get }
}

extension RelayConnection: RelayLink {}
