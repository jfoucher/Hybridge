import Foundation
import CoreBluetooth

/// Base for the physical hand-control writes on 3dda0002 (GB's misfit-style
/// requests, still used by the Hybrid HR). First byte 0x02 means the watch
/// sends no response, so the request finishes as soon as the write goes out.
class HandControlRequest: FossilRequest {
    override var startUUID: CBUUID { FossilUUID.char0002 }

    func payload() throws -> Data {
        fatalError("payload not implemented")
    }

    override func startData() throws -> Data {
        isFinished = true
        return try payload()
    }
}

/// Takes physical control of the hands away from the watch
/// (GB: RequestHandControlRequest — priority 1, no notifications).
final class RequestHandsControlRequest: HandControlRequest {
    override func payload() throws -> Data {
        Data([0x02, 0x15, 0x01, 0x01, 0x00, 0x00])
    }
}

/// Returns control of the hands to the watch, which then re-syncs them to
/// the current time (GB: ReleaseHandsControlRequest, zero delay).
final class ReleaseHandsControlRequest: HandControlRequest {
    override func payload() throws -> Data {
        Data([0x02, 0x15, 0x02, 0x00, 0x00])
    }
}

/// Moves one or more hands while hands control is held
/// (GB: MoveHandsRequest with isHybridHR = true).
final class MoveHandsRequest: HandControlRequest {
    /// Degrees per hand; nil leaves that hand alone. Relative moves take
    /// signed degrees (positive = clockwise), absolute moves a 0–359 target.
    /// The HR has no sub-eye, but the protocol field is kept for completeness.
    private let relative: Bool
    private let hands: [(id: UInt8, degrees: Int)]
    /// GB's !isHybridHR quirk: the non-HR movements can't step a hand by
    /// exactly 1°, so |1°| becomes 2° (direction preserved).
    private let bumpSingleDegree: Bool

    init(relative: Bool, hour: Int? = nil, minute: Int? = nil, sub: Int? = nil,
         bumpSingleDegree: Bool = false) {
        self.relative = relative
        self.bumpSingleDegree = bumpSingleDegree
        var hands: [(UInt8, Int)] = []
        if let hour { hands.append((1, hour)) }
        if let minute { hands.append((2, minute)) }
        if let sub { hands.append((3, sub)) }
        self.hands = hands
    }

    override func payload() throws -> Data {
        var data = Data([0x02, 0x15, 0x03,
                         relative ? 0x01 : 0x02,
                         UInt8(hands.count)])
        for hand in hands {
            var degrees = UInt16(abs(hand.degrees))
            if bumpSingleDegree && degrees == 1 { degrees = 2 }
            data.append(hand.id)
            data.appendUInt16LE(degrees)
            // Direction: 1 = clockwise, 2 = counter-clockwise, 3 = shortest
            // path (absolute moves).
            data.append(relative ? (hand.degrees >= 0 ? 0x01 : 0x02) : 0x03)
            data.append(0x01)   // speed
        }
        return data
    }
}

/// Persists the current physical hand positions as the new zero position
/// (GB: SaveCalibrationRequest).
final class SaveCalibrationRequest: HandControlRequest {
    override func payload() throws -> Data {
        Data([0x02, 0xF2, 0x0E])
    }
}
