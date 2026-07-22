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
    /// Watchdog: the request fails after this much *silence* (no response
    /// from the watch, no outgoing packet). Any activity resets the timer.
    var idleTimeout: TimeInterval { 12 }
    var onProgress: ((Double) -> Void)?

    /// Initial payload written when the request starts.
    func startData() throws -> Data {
        fatalError("startData not implemented")
    }

    /// Process a notification. Throw to abort the request.
    func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
    }
}
