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
