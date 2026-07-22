import Foundation
import CoreBluetooth

/// Raw vibration writes on 3dda0005 for the non-HR Q hybrids (GB:
/// FossilWatchAdapter.vibrateStartCall / vibrateEndCall — used there for
/// incoming calls and find-device). Fire-and-forget: no response frame.
final class QVibrateRequest: FossilRequest {
    private let start: Bool

    init(start: Bool) {
        self.start = start
    }

    override var name: String { start ? "QVibrateStart" : "QVibrateStop" }
    override var startUUID: CBUUID { FossilUUID.char0005 }

    override func startData() throws -> Data {
        isFinished = true
        return start
            ? Data([0x01, 0x04, 0x30, 0x75, 0x00, 0x00])
            : Data([0x02, 0x05, 0x04])
    }
}

/// Vibrates a non-HR Q hybrid to be found and stays in flight to catch the
/// button-press acknowledgement — the Q equivalent of the HR
/// `ConfirmOnDeviceRequest`. The start write is the same `QVibrateRequest`
/// vibrate-call frame (`0x01, 0x04, …`, 30 s window); the firmware answers
/// `[0x03, 0x04, 0x00]` on 3dda0005 when the user presses the middle button,
/// which also stops the vibration watch-side — verified against a real Q
/// Grant. Gadgetbridge treats vibrate as fire-and-forget and never reads this
/// ack. The watch stays silent when its own window lapses without a press, so
/// the caller relies on `run`'s idle-timeout (surfaced as `FossilError.timeout`)
/// for the unconfirmed case rather than a status frame.
final class QConfirmOnDeviceRequest: FossilRequest {
    private(set) var confirmed = false

    override var name: String { "QConfirmOnDevice" }
    override var startUUID: CBUUID { FossilUUID.char0005 }

    /// The ack arrives only on a button press; nothing comes when the ~30 s
    /// vibration window lapses, so allow more silence than the watch's window.
    override var idleTimeout: TimeInterval { 33 }

    override func startData() throws -> Data {
        Data([0x01, 0x04, 0x30, 0x75, 0x00, 0x00])
    }

    override func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
        guard uuid == FossilUUID.char0005 else { return }
        guard value.count >= 2, value.u8(at: 0) == 0x03, value.u8(at: 1) == 0x04 else {
            throw FossilError.unexpectedResponse("Q confirm-on-device response: \(value.hexString)")
        }
        confirmed = true
        isFinished = true
    }
}

/// Plays the pairing animation — the watch sweeps its hands (GB: misfit
/// AnimationRequest, also used by FossilWatchAdapter.playPairingAnimation).
/// Fire-and-forget on the command channel.
final class PairingAnimationRequest: FossilRequest {
    override var startUUID: CBUUID { FossilUUID.char0002 }

    override func startData() throws -> Data {
        isFinished = true
        return Data([0x02, 0xF1, 0x05])
    }
}
