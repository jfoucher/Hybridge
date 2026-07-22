import Foundation
import CoreBluetooth

/// Asks the watch whether it has a BLE bond with this phone
/// (GB: CheckDevicePairingRequest). Plain control exchange on 3dda0002:
/// write [0x01, 0x16], watch answers [0x03, 0x16, status].
class CheckDevicePairingRequest: FossilRequest {
    /// Set from the response status byte (0x01 = bonded).
    private(set) var isPaired = false

    override var startUUID: CBUUID { FossilUUID.char0002 }

    override func startData() throws -> Data {
        Data([0x01, 0x16])
    }

    override func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
        guard uuid == FossilUUID.char0002 else { return }
        guard value.count == 3, value.u8(at: 0) == 0x03, value.u8(at: 1) == 0x16 else {
            throw FossilError.unexpectedResponse("pairing response: \(value.hexString)")
        }
        isPaired = value.u8(at: 2) == 0x01
        isFinished = true
    }
}

/// Makes the watch vibrate and show its confirmation animation for ~30 s —
/// used as "find my watch" (GB: ConfirmOnDeviceRequest, FW ≥ 2.22).
/// Write [0x02, 0x06, timeout u16 LE ms, 0x00, 0x00, 0x00] on 3dda0005; the
/// watch answers [0x03, 0x06, 0x00, status] once the user presses a button
/// (status 0x01) or the timeout expires.
final class ConfirmOnDeviceRequest: FossilRequest {
    private(set) var confirmed = false

    override var startUUID: CBUUID { FossilUUID.char0005 }

    /// The reply only arrives on button press or after the watch-side 30 s
    /// timeout, so allow more silence than usual.
    override var idleTimeout: TimeInterval { 35 }

    override func startData() throws -> Data {
        Data([0x02, 0x06, 0x30, 0x75, 0x00, 0x00, 0x00])
    }

    override func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
        guard uuid == FossilUUID.char0005 else { return }
        guard value.count == 4, value.u8(at: 0) == 0x03, value.u8(at: 1) == 0x06,
              value.u8(at: 2) == 0x00 else {
            throw FossilError.unexpectedResponse("confirm-on-device response: \(value.hexString)")
        }
        confirmed = value.u8(at: 3) == 0x01
        isFinished = true
    }
}

/// Wipes the watch and reboots it into factory state
/// (GB: FactoryResetRequest). Fire-and-forget on 3dda0002 — the watch drops
/// the connection while resetting.
final class FactoryResetRequest: FossilRequest {
    override var startUUID: CBUUID { FossilUUID.char0002 }

    override func startData() throws -> Data {
        isFinished = true
        return Data([0x02, 0xF1, 0x23, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }
}

/// Tells the watch to initiate BLE pairing (GB: PerformDevicePairingRequest).
/// The watch sends a security request, which makes iOS show the system
/// pairing dialog and then the "allow notifications" (ANCS) prompt — an app
/// cannot trigger bonding itself on iOS. Once bonded the watch gets native
/// access to ANCS (notifications) and AMS (music metadata + system volume).
final class PerformDevicePairingRequest: CheckDevicePairingRequest {
    /// The watch only answers after the user accepts/declines the iOS
    /// pairing dialog, so allow much more silence than usual.
    override var idleTimeout: TimeInterval { 60 }

    override func startData() throws -> Data {
        Data([0x02, 0x16])
    }
}
