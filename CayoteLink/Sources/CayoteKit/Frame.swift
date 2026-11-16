import Foundation

/// Frame format shared by Cayote's updater and the charger (docs/PROTOCOL.md §2):
///
///     A5 A5 A5 A5 A5 | dst | src | len | payload[len] | sumLo | sumHi
///
/// After the preamble, every run of four 0xA5 bytes is followed by a stuffed 0xCC.
public enum Frame {
    public static let preambleByte: UInt8 = 0xA5
    public static let preambleLength = 5
    public static let stuffByte: UInt8 = 0xCC
    /// Address of the PC side.
    public static let hostAddress: UInt8 = 0x20
    /// Address of the charger side.
    public static let chargerAddress: UInt8 = 0x11
    public static let maxPayload = 255

    /// 16-bit sum over dst, src, len and the payload.
    public static func checksum(dst: UInt8, src: UInt8, payload: [UInt8]) -> UInt16 {
        var s = UInt16(dst) &+ UInt16(src) &+ UInt16(payload.count)
        for b in payload { s = s &+ UInt16(b) }
        return s
    }

    /// Encode a frame exactly as the official updater does (FUN_00407380).
    public static func encode(dst: UInt8, src: UInt8, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= maxPayload, "payload too long")
        var out = [UInt8](repeating: preambleByte, count: preambleLength)
        out.reserveCapacity(preambleLength + payload.count + 16)
        var run = 0
        func put(_ b: UInt8) {
            out.append(b)
            if b == preambleByte {
                run += 1
                if run == 4 {
                    out.append(stuffByte)
                    run = 0
                }
            } else {
                run = 0
            }
        }
        let sum = checksum(dst: dst, src: src, payload: payload)
        put(dst)
        put(src)
        put(UInt8(payload.count))
        payload.forEach(put)
        put(UInt8(sum & 0xFF))
        out.append(UInt8(sum >> 8)) // the last byte is never followed by a stuffing byte
        return out
    }

    /// Request from the PC to the charger.
    public static func request(_ payload: [UInt8]) -> [UInt8] {
        encode(dst: chargerAddress, src: hostAddress, payload: payload)
    }

    /// Reply from the charger to the PC.
    public static func reply(_ payload: [UInt8]) -> [UInt8] {
        encode(dst: hostAddress, src: chargerAddress, payload: payload)
    }

    /// Cut a byte stream into fixed-size HID reports, zero-padding the last.
    public static func reports(_ stream: [UInt8], size: Int = 64) -> [Data] {
        guard !stream.isEmpty else { return [] }
        var result: [Data] = []
        var i = 0
        while i < stream.count {
            var chunk = Array(stream[i..<min(i + size, stream.count)])
            chunk += [UInt8](repeating: 0, count: size - chunk.count)
            result.append(Data(chunk))
            i += size
        }
        return result
    }
}

/// A received frame.
public struct ReceivedFrame: Equatable, Sendable {
    public var dst: UInt8
    public var src: UInt8
    public var payload: [UInt8]
    public var command: UInt8? { payload.first }
}

/// Byte-at-a-time frame parser, equivalent to the updater's FUN_00407500 and
/// the firmware's receiver. Bytes outside a frame (e.g. report padding) are ignored.
public struct FrameParser {
    private enum State { case idle, dst, src, len, payload, sumLo, sumHi }
    /// The parser only accepts frames whose second byte (src) is this value.
    public let expectedSource: UInt8
    private var state = State.idle
    private var preambleCount = 0
    private var escapeRun = 0
    private var dst: UInt8 = 0
    private var length = 0
    private var payload: [UInt8] = []
    private var sum: UInt16 = 0

    public init(expectedSource: UInt8) {
        self.expectedSource = expectedSource
    }

    public mutating func reset() {
        state = .idle
        preambleCount = 0
        escapeRun = 0
    }

    /// Feed one byte; returns a frame when one completes.
    public mutating func feed(_ b: UInt8) -> ReceivedFrame? {
        if state == .idle {
            escapeRun = 0
            if b == Frame.preambleByte {
                preambleCount += 1
                if preambleCount >= Frame.preambleLength {
                    preambleCount = 0
                    state = .dst
                }
            } else {
                preambleCount = 0
            }
            return nil
        }
        // Drop the stuffing byte that follows four 0xA5 bytes.
        if escapeRun > 3 {
            escapeRun = 0
            return nil
        }
        escapeRun = b == Frame.preambleByte ? escapeRun + 1 : 0

        switch state {
        case .idle:
            return nil
        case .dst:
            dst = b
            sum = UInt16(b)
            state = .src
        case .src:
            guard b == expectedSource else { state = .idle; return nil }
            sum &+= UInt16(b)
            state = .len
        case .len:
            length = Int(b)
            sum &+= UInt16(b)
            payload = []
            payload.reserveCapacity(length)
            state = length == 0 ? .sumLo : .payload
        case .payload:
            payload.append(b)
            sum &+= UInt16(b)
            if payload.count >= length { state = .sumLo }
        case .sumLo:
            state = b == UInt8(sum & 0xFF) ? .sumHi : .idle
        case .sumHi:
            state = .idle
            if b == UInt8(sum >> 8) {
                return ReceivedFrame(dst: dst, src: expectedSource, payload: payload)
            }
        }
        return nil
    }

    public mutating func feed(_ data: Data) -> [ReceivedFrame] {
        var frames: [ReceivedFrame] = []
        for b in data {
            if let f = feed(b) { frames.append(f) }
        }
        return frames
    }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
}

func readLE32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

func readLE16(_ b: [UInt8], _ o: Int) -> UInt16 {
    UInt16(b[o]) | UInt16(b[o + 1]) << 8
}
