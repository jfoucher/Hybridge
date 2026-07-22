import Foundation

/// One minute of activity data from the watch.
struct ActivitySample: Codable, Equatable, Sendable {
    var timestamp: Int          // Unix seconds (start of the minute)
    var stepCount: Int
    var calories: Int
    var heartRate: Int          // 0/255 = no reading
    var variability: Int
    var maxVariability: Int
    var heartRateQuality: Int
    var isActive: Bool
    var wearingState: Int       // 0 wearing, 1 not wearing, 2 unknown
    /// Which watch recorded it (nil in pre-multi-watch archives until the
    /// one-time adoption tags them).
    var watchID: UUID?

    var hasValidHeartRate: Bool {
        wearingState == 0 && heartRate > 30 && heartRate < 230 && heartRateQuality > 0
    }
}

struct SpO2Sample: Codable, Equatable, Sendable {
    var timestamp: Int
    var value: Int
    var watchID: UUID?
}

struct WorkoutSummary: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: String
    var startTimestamp: Int
    var endTimestamp: Int
    // Optionals: absent in files recorded before these fields were parsed
    // (and in records where the watch stores all-0xFF placeholders).
    var steps: Int?
    var distanceMeters: Int?
    var calories: Int?
    var averageHeartRate: Int?
    var maxHeartRate: Int?
    var watchID: UUID?
}

/// Parses the Fossil activity file format (file version 22, both the HR
/// marker-stream variant and the flat no-HR variant). 
/// Operates on the raw decrypted activity file, header included.
struct ActivityParser {
    private(set) var samples: [ActivitySample] = []
    private(set) var spo2Samples: [SpO2Sample] = []
    private(set) var workouts: [WorkoutSummary] = []
    /// Defensive deletion invariant: only a parser that reached the exact end
    /// of the structurally validated record stream reports completeness.
    private(set) var isComplete = false

    private var heartRateQuality = 0
    private var wearingState = 0
    private var currentTimestamp = 0
    private var pending: PendingSample?

    private struct PendingSample {
        var stepCount = 0
        var variability = 0
        var maxVariability = 0
        var heartRate = 0
        var calories = 0
        var isActive = false
    }

    enum ParseError: Error, Equatable {
        case tooShort
        case unsupportedVersion(Int)
        case truncated(offset: Int, context: String)
        case invalidRecord(offset: Int, marker: UInt8)
        case invalidWorkout(offset: Int, context: String)
        case invalidTermination(offset: Int)
    }

    static func parse(_ file: Data) throws -> ActivityParser {
        var parser = ActivityParser()
        try parser.run(file)
        return parser
    }

    private mutating func run(_ file: Data) throws {
        guard file.count > 56 else { throw ParseError.tooShort }
        let version = Int(file.u16LE(at: 2))
        guard version == 22 else { throw ParseError.unsupportedVersion(version) }
        currentTimestamp = Int(file.u32LE(at: 8))

        let markers: Set<UInt8> = [0xCE, 0xC2, 0xE2, 0xE0, 0xDD, 0xD6, 0xCB, 0xCC, 0xCF]
        if markers.contains(file.u8(at: 52)) {
            try parseHrVariant(file)
        } else {
            try parseNoHrVariant(file)
        }
        isComplete = true
    }

    // MARK: No-HR variant: fixed 4-byte records from offset 44, interleaved
    // with occasional clock-resync records the flat layout doesn't warn about
    // up front.

    private mutating func parseNoHrVariant(_ file: Data) throws {
        currentTimestamp = Int(file.u32LE(at: 34))
        var pos = 44
        let contentEnd = file.count - 4
        guard contentEnd >= pos else {
            throw ParseError.invalidTermination(offset: pos)
        }
        while pos < contentEnd {
            let marker = file.u8(at: pos)

            // Clock-resync record: 0xE2, one subcode byte, a 4-byte LE Unix
            // timestamp, then 4 further bytes of unknown purpose. Verified
            // byte-exact against a real Q Grant dump where the first
            // occurrence's embedded timestamp equals the file's offset-8/34
            // header timestamp; does not itself produce a sample.
            if marker == 0xE2 {
                guard pos + 10 <= contentEnd else {
                    throw ParseError.truncated(offset: pos, context: "no-HR timestamp resync record")
                }
                currentTimestamp = Int(file.u32LE(at: pos + 2))
                pos += 10
                continue
            }

            // Two-byte filler seen between resync records; no known payload.
            if marker == 0xFE, pos + 2 <= contentEnd, file.u8(at: pos + 1) == 0xFE {
                pos += 2
                continue
            }

            guard pos + 4 <= contentEnd else {
                throw ParseError.truncated(offset: pos, context: "activity sample")
            }
            let varLo = Int(marker)
            let varHi = Int(file.u8(at: pos + 1))
            let hrByte = Int(file.u8(at: pos + 2))
            let flags = Int(file.u8(at: pos + 3))
            guard hrByte == 0xFF else {
                throw ParseError.invalidRecord(offset: pos, marker: UInt8(hrByte))
            }

            var entry = PendingSample()
            parseVariability(lower: varLo, higher: varHi, into: &entry)
            entry.isActive = (flags & 0x40) == 0x40
            entry.calories = flags & 0x3F
            samples.append(ActivitySample(timestamp: currentTimestamp,
                                          stepCount: entry.stepCount,
                                          calories: entry.calories,
                                          heartRate: 0,
                                          variability: entry.variability,
                                          maxVariability: entry.maxVariability,
                                          heartRateQuality: 0,
                                          isActive: entry.isActive,
                                          wearingState: 0))
            currentTimestamp += 60
            pos += 4
        }
        guard pos == contentEnd else {
            throw ParseError.invalidTermination(offset: pos)
        }
    }

    // MARK: HR variant: marker stream from offset 52

    private mutating func parseHrVariant(_ file: Data) throws {
        let contentEnd = file.count - 4
        var reader = ByteReader(data: file, position: 52, limit: contentEnd)
        finishPending()

        while reader.position < contentEnd {
            let markerOffset = reader.position
            guard let next = reader.readByte() else {
                throw ParseError.truncated(offset: markerOffset, context: "record marker")
            }
            switch next {
            case 0xCE:
                guard let wearByte = reader.readByte(),
                      let f1 = reader.readByte(),
                      let f2 = reader.readByte() else {
                    throw ParseError.truncated(offset: reader.position, context: "heart-rate record header")
                }
                parseWearByte(wearByte)

                if f1 == 0xE2 && f2 == 0x04 {
                    guard let timestamp = reader.readU32LE(),
                          reader.readU16LE() != nil,
                          reader.readU16LE() != nil else {
                        throw ParseError.truncated(offset: reader.position, context: "timestamp record")
                    }
                    currentTimestamp = Int(timestamp)
                } else if f1 == 0xD3 {
                    // Workout-related extras; skip fields like the Java code.
                    guard reader.skip(2), let v1 = reader.readByte() else {
                        throw ParseError.truncated(offset: reader.position, context: "workout heart-rate record")
                    }
                    let v2 = reader.peek(0) ?? 0
                    // Bounds-checked look-back (was a raw `file.u8` that would
                    // trap on a short/corrupt file): 0 is a safe "not 0x08".
                    let infoB0 = reader.peek(-3) ?? 0
                    if v1 == 0xDF {
                        _ = v2
                        guard reader.skip(1) else {
                            throw ParseError.truncated(offset: reader.position, context: "workout maximum heart rate")
                        }
                        if infoB0 == 0x08 {
                            guard reader.skip(11) else {
                                throw ParseError.truncated(offset: reader.position, context: "workout statistics")
                            }
                        } else if let probe = reader.peek(4), !Self.isMarker(probe) {
                            guard reader.skip(3) else {
                                throw ParseError.truncated(offset: reader.position, context: "workout statistics")
                            }
                        }
                    } else if v1 == 0xE2 && v2 == 0x04 {
                        guard reader.skip(13) else {
                            throw ParseError.truncated(offset: reader.position, context: "workout timestamp")
                        }
                        if let probe = reader.peek(0), !Self.isMarker(probe) {
                            guard reader.skip(3) else {
                                throw ParseError.truncated(offset: reader.position, context: "workout timestamp suffix")
                            }
                        }
                    } else if let probe = reader.peek(4), !Self.isMarker(probe) {
                        guard reader.skip(1) else {
                            throw ParseError.truncated(offset: reader.position, context: "workout extension")
                        }
                    }
                } else if f1 == 0xCF || f1 == 0xDF {
                    continue
                } else if f1 == 0xD6 {
                    guard let spo2 = reader.readByte() else {
                        throw ParseError.truncated(offset: reader.position, context: "SpO2 value")
                    }
                    spo2Samples.append(SpO2Sample(timestamp: currentTimestamp, value: Int(spo2)))
                    guard reader.skip(3) else {
                        throw ParseError.truncated(offset: reader.position, context: "SpO2 statistics")
                    }
                } else if f1 == 0xFE && f2 == 0xFE {
                    if reader.peek(0) == 0xFE { _ = reader.readByte() }
                } else if let probe = reader.peek(2), Self.isMarker(probe) {
                    // Compact record: f1/f2 already are the variability bytes.
                    ensurePending()
                    parseVariability(lower: Int(f1), higher: Int(f2), into: &pending!)
                    guard let heartRate = reader.readByte(), let caloriesRaw = reader.readByte() else {
                        throw ParseError.truncated(offset: reader.position, context: "compact activity sample")
                    }
                    pending!.heartRate = Int(heartRate)
                    pending!.isActive = (caloriesRaw & 0x40) == 0x40
                    pending!.calories = Int(caloriesRaw & 0x3F)
                    finishPending()
                    continue
                }

                if reader.position > contentEnd {
                    throw ParseError.invalidTermination(offset: reader.position)
                }

                guard let varLo = reader.readByte(), let varHi = reader.readByte(),
                      let heartRate = reader.readByte(), let caloriesRaw = reader.readByte() else {
                    throw ParseError.truncated(offset: reader.position, context: "activity sample")
                }
                ensurePending()
                parseVariability(lower: Int(varLo), higher: Int(varHi), into: &pending!)
                pending!.heartRate = Int(heartRate)
                pending!.isActive = (caloriesRaw & 0x40) == 0x40
                pending!.calories = Int(caloriesRaw & 0x3F)
                finishPending()

            case 0xC2:
                guard reader.skip(3) else {
                    throw ParseError.truncated(offset: reader.position, context: "C2 record")
                }

            case 0xE2:
                guard reader.skip(9) else {
                    throw ParseError.truncated(offset: reader.position, context: "E2 record")
                }
                if let probe = reader.peek(0), !Self.isMarker(probe) {
                    guard reader.skip(6) else {
                        throw ParseError.truncated(offset: reader.position, context: "E2 extension")
                    }
                }

            case 0xE0:
                try parseWorkoutSummary(&reader)

            case 0xDD:
                guard reader.skip(20) else {
                    throw ParseError.truncated(offset: reader.position, context: "DD record")
                }

            case 0xD6:
                guard reader.skip(1), let spo2 = reader.readByte() else {
                    throw ParseError.truncated(offset: reader.position, context: "D6 SpO2 record")
                }
                spo2Samples.append(SpO2Sample(timestamp: currentTimestamp, value: Int(spo2)))

            case 0xCB, 0xCC, 0xCF:
                guard reader.skip(1) else {
                    throw ParseError.truncated(offset: reader.position, context: "short marker record")
                }

            case 0x00:
                // Captured files use zero padding between the last record and
                // the container CRC. Padding is a legitimate terminator only
                // when every remaining content byte is also zero.
                guard reader.data[reader.position..<contentEnd].allSatisfy({ $0 == 0 }) else {
                    throw ParseError.invalidRecord(offset: markerOffset, marker: next)
                }
                guard reader.skip(contentEnd - reader.position) else {
                    throw ParseError.invalidTermination(offset: reader.position)
                }

            default:
                throw ParseError.invalidRecord(offset: markerOffset, marker: next)
            }
        }
        guard reader.position == contentEnd else {
            throw ParseError.invalidTermination(offset: reader.position)
        }
    }

    private mutating func parseWorkoutSummary(_ reader: inout ByteReader) throws {
        var summary = WorkoutSummary(kind: "Activity", startTimestamp: 0, endTimestamp: 0)
        var duration = 0
        for _ in 0..<14 {
            guard let attributeId = reader.readByte(), let size = reader.readByte(),
                  reader.position + Int(size) <= reader.limit else {
                throw ParseError.invalidWorkout(offset: reader.position,
                                                context: "truncated attribute")
            }
            let info = reader.data.slice(reader.position, Int(size))
            _ = reader.skip(Int(size))
            // The watch stores all-0xFF for attributes it didn't record
            // (GB: HybridHRWorkoutSummaryParser skips those).
            if info.allSatisfy({ $0 == 0xFF }) { continue }
            switch attributeId {
            case 2 where info.count >= 4:
                duration = Int(info.u32LE(at: 0))
            case 4 where info.count >= 4:
                summary.steps = Int(info.u32LE(at: 0))
            case 5 where info.count >= 4:
                summary.distanceMeters = Int(info.u32LE(at: 0)) / 100   // stored in cm
            case 6 where info.count >= 4:
                summary.calories = Int(info.u32LE(at: 0))
            case 7 where info.count >= 1:
                summary.averageHeartRate = Int(info.u8(at: 0))
            case 8 where info.count >= 1:
                summary.maxHeartRate = Int(info.u8(at: 0))
            case 9 where info.count >= 1:
                switch info.u8(at: 0) {
                case 0x01: summary.kind = "Running"
                case 0x02: summary.kind = "Cycling"
                case 0x03: summary.kind = "Treadmill"
                case 0x04: summary.kind = "Cross trainer"
                case 0x05: summary.kind = "Weightlifting"
                case 0x06: summary.kind = "Training"
                case 0x08: summary.kind = "Walking"
                case 0x09: summary.kind = "Rowing machine"
                case 0x0C: summary.kind = "Hiking"
                case 0x0D: summary.kind = "Spinning"
                default: break
                }
            default:
                break
            }
        }
        summary.startTimestamp = currentTimestamp - duration
        summary.endTimestamp = currentTimestamp
        workouts.append(summary)
    }

    // MARK: Shared helpers (verbatim ports)

    private static func isMarker(_ value: UInt8) -> Bool {
        [0xCE, 0xDD, 0xCB, 0xCC, 0xCF, 0xD6, 0xE2].contains(value)
    }

    private func parseVariability(lower: Int, higher: Int, into sample: inout PendingSample) {
        if (lower & 0b1) == 0b1 {
            sample.maxVariability = (higher & 0b11) * 25 + 1
            sample.stepCount = lower & 0b1110
            if (lower & 0b1000_0000) == 0b1000_0000 {
                let factor = (lower >> 4) & 0b111
                sample.variability = 512 + factor * 64 + ((higher >> 2) & 0b11_1111)
            } else {
                sample.variability = (lower & 0b0111_0000) << 2
                sample.variability |= (higher >> 2) & 0b11_1111
            }
        } else {
            sample.stepCount = lower & 0b1111_1110
            sample.variability = higher * higher * 64
            sample.maxVariability = 10000
        }
    }

    private mutating func parseWearByte(_ wearArg: UInt8) {
        let wearBits = (wearArg & 0b0001_1000) >> 3
        switch wearBits {
        case 0: wearingState = 1   // NOT_WEARING
        case 1: wearingState = 0   // WEARING
        default: wearingState = 2  // UNKNOWN
        }
        heartRateQuality = Int((wearArg & 0b1110_0000) >> 5)
    }

    private mutating func ensurePending() {
        if pending == nil { pending = PendingSample() }
    }

    private mutating func finishPending() {
        if let sample = pending {
            samples.append(ActivitySample(timestamp: currentTimestamp,
                                          stepCount: sample.stepCount,
                                          calories: sample.calories,
                                          heartRate: sample.heartRate,
                                          variability: sample.variability,
                                          maxVariability: sample.maxVariability,
                                          heartRateQuality: heartRateQuality,
                                          isActive: sample.isActive,
                                          wearingState: wearingState))
            currentTimestamp += 60
        }
        pending = PendingSample()
    }
}

/// Bounds-checked sequential reader (Java ByteBuffer-like semantics).
struct ByteReader {
    let data: Data
    var position: Int
    let limit: Int

    mutating func readByte() -> UInt8? {
        guard position < limit else { return nil }
        defer { position += 1 }
        return data.u8(at: position)
    }

    mutating func readU16LE() -> UInt16? {
        guard position + 2 <= limit else { return nil }
        defer { position += 2 }
        return data.u16LE(at: position)
    }

    mutating func readU32LE() -> UInt32? {
        guard position + 4 <= limit else { return nil }
        defer { position += 4 }
        return data.u32LE(at: position)
    }

    /// Peek at position + offset without advancing. `offset` may be negative
    /// (some records look back a few bytes); an out-of-range index — below 0 or
    /// past the end — returns nil rather than trapping.
    func peek(_ offset: Int) -> UInt8? {
        let index = position + offset
        guard index >= 0, index < limit else { return nil }
        return data.u8(at: index)
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, position + count <= limit else {
            position = limit
            return false
        }
        position += count
        return true
    }
}
