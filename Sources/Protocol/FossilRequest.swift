import Foundation
import CoreBluetooth

/// Interface the request state machines use to talk back to the BLE layer.
protocol RequestIO: AnyObject {
    /// Write a control payload to the given characteristic.
    func write(_ data: Data, to uuid: CBUUID)
    /// Stream pre-built file packets to 3dda0004, one after the other.
    func writeFilePackets(_ packets: [Data])
    /// Negotiated max payload per file packet, minus the 1-byte sequence index.
    var maxFilePacketPayload: Int { get }
}

/// One serialized protocol exchange with the watch. Only a single request is
/// in flight at any time (the firmware wedges otherwise); the queue in
/// WatchManager routes every notification to the current request until
/// `isFinished` is true.
class FossilRequest {
    var name: String { String(describing: type(of: self)) }
    /// Characteristic the start sequence is written to.
    var startUUID: CBUUID { FossilUUID.char0003 }
    var isFinished = false
    /// A large multi-packet file transfer (put/get/firmware). The fleet
    /// serializes these across all watches so two watches streaming a file at
    /// once don't starve each other's radio and trip the idle watchdog — the
    /// failure mode a mis-timed encrypted config put most fears. Small control
    /// exchanges (lookup, delete, config item writes) leave this false.
    var isBulkTransfer: Bool { false }
    /// Per-instance watchdog override. The watchface rescue path sets it so a
    /// request swallowed by a rebooting watch fails inside the few seconds its
    /// window still has left, instead of eating the whole window.
    var idleTimeoutOverride: TimeInterval?
    /// The file handle whose session this request may have left open if it dies
    /// mid-transfer. The queue fires a best-effort close (`[09][handle]`) for
    /// it on failure: an open the watch never got to finish wedges its file
    /// socket, and every later open — on any handle — is then refused. nil for
    /// requests that own no session.
    var openSessionHandle: UInt16? { nil }
    /// A request the watch never answers, which is complete once its single
    /// write is acknowledged by the ATT layer. Setting `isFinished` in
    /// `startData()` instead reports success before the write is even
    /// delivered — a factory reset logged `✓` and *then* `write FAILED`, which
    /// left "did the watch get it?" unanswerable.
    var finishesOnWriteAck: Bool { false }
    /// Watchdog: the request fails after this much *silence* (no response
    /// from the watch, no outgoing packet). Any activity resets the timer.
    var idleTimeout: TimeInterval { idleTimeoutOverride ?? 12 }
    var onProgress: ((Double) -> Void)?

    /// Initial payload written when the request starts.
    func startData() throws -> Data {
        throw FossilError.unexpectedResponse("\(name) has no start payload")
    }

    /// Process a notification. Throw to abort the request.
    func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
    }
}
