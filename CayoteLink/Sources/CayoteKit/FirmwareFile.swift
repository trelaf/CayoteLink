import Foundation

/// Version triple as shown by the charger ("SOFTWARE: 1.2.9").
public struct Version: Comparable, CustomStringConvertible, Sendable, Hashable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "1.2.9" or "V1.2.9".
    public init?(_ text: String) {
        let t = text.hasPrefix("V") || text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = t.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let a = parts[0], let b = parts[1], let c = parts[2] else { return nil }
        self.init(a, b, c)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (l: Version, r: Version) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}

/// The 0x48-byte identity block (docs/PROTOCOL.md §4): `.grp` header 0x10–0x57,
/// a copy inside the firmware, and offset 0x14 of the Identify reply.
public struct IdentityBlock: Equatable, Sendable {
    public static let size = 0x48
    public static let magic: UInt32 = 0x1234_5678
    public var bytes: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= Self.size else { return nil }
        self.bytes = Array(bytes.prefix(Self.size))
    }

    public static func make(vendor: String, model: String, hardware: Version, software: Version) -> IdentityBlock {
        var b = [UInt8](repeating: 0, count: size)
        b.replaceSubrange(0..<4, with: le32(magic))
        let v = Array(vendor.utf8.prefix(39))
        b.replaceSubrange(4..<(4 + v.count), with: v)
        let m = Array(model.utf8.prefix(19))
        b.replaceSubrange(0x2C..<(0x2C + m.count), with: m)
        b[0x40] = UInt8(hardware.major)
        b[0x41] = UInt8(hardware.minor)
        b[0x42] = UInt8(software.major)
        b[0x43] = UInt8(software.minor)
        b[0x44] = UInt8(hardware.patch & 0xFF); b[0x45] = UInt8(hardware.patch >> 8)
        b[0x46] = UInt8(software.patch & 0xFF); b[0x47] = UInt8(software.patch >> 8)
        return IdentityBlock(b)!
    }

    private func cString(_ range: Range<Int>) -> String {
        let raw = bytes[range].prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }

    public var hasMagic: Bool { readLE32(bytes, 0) == Self.magic }
    public var vendor: String { cString(0x04..<0x2C) }
    public var model: String { cString(0x2C..<0x40) }
    public var hardware: Version { Version(Int(bytes[0x40]), Int(bytes[0x41]), Int(readLE16(bytes, 0x44))) }
    public var software: Version { Version(Int(bytes[0x42]), Int(bytes[0x43]), Int(readLE16(bytes, 0x46))) }

    /// The three bytes the official updater compares: hardware major, hardware minor, software major.
    public var compatibilityKey: [UInt8] { Array(bytes[0x40...0x42]) }

    /// The updater's identity check (FUN_00407BB0): same compatibility bytes,
    /// same vendor (first 40 bytes) and same model (first 20 bytes; "G6 Devices" files
    /// also accept "G6" and "G6 Pro").
    public func accepts(charger: IdentityBlock) -> Bool {
        guard compatibilityKey == charger.compatibilityKey else { return false }
        guard strncmpEqual(Array(bytes[0x04..<0x2C]), Array(charger.bytes[0x04..<0x2C])) else { return false }
        if model == "G6 Devices" {
            return ["G6", "G6 Pro", "G6 Devices"].contains(charger.model)
        }
        return strncmpEqual(Array(bytes[0x2C..<0x40]), Array(charger.bytes[0x2C..<0x40]))
    }

    /// Why `accepts` would fail, in words (nil if it would succeed).
    public func mismatch(charger: IdentityBlock) -> String? {
        if accepts(charger: charger) { return nil }
        if model != charger.model { return "the file is for \"\(model)\", the charger is \"\(charger.model)\"" }
        if vendor != charger.vendor { return "the file is from \"\(vendor)\", the charger from \"\(charger.vendor)\"" }
        return "the file needs hardware \(hardware.major).\(hardware.minor) and firmware \(software.major).x; "
            + "the charger reports hardware \(charger.hardware.major).\(charger.hardware.minor) "
            + "and firmware \(charger.software.major).x"
    }
}

/// strncmp semantics: equal up to and including the first NUL.
private func strncmpEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    for i in 0..<min(a.count, b.count) {
        if a[i] != b[i] { return false }
        if a[i] == 0 { return true }
    }
    return a.count == b.count
}

public enum Checksum {
    /// Sum of little-endian 32-bit words; a 1–3 byte tail counts as a zero-padded word (FUN_004072A0).
    public static func sum32<C: Collection>(_ data: C) -> UInt32 where C.Element == UInt8 {
        var s: UInt32 = 0
        var word: UInt32 = 0
        var shift: UInt32 = 0
        for b in data {
            word |= UInt32(b) << shift
            shift += 8
            if shift == 32 {
                s &+= word
                word = 0
                shift = 0
            }
        }
        if shift > 0 { s &+= word }
        return s
    }
}

/// A Cayote / Grepow firmware file (`.grp`): 0x5C-byte header plus a raw image.
public struct FirmwareFile: Sendable {
    public static let headerSize = 0x5C
    /// The bootloader occupies 0x08000000–0x08003FFF; the official updater only accepts this address.
    public static let requiredLoadAddress: UInt32 = 0x0800_4000

    public let data: Data
    public var header: [UInt8] { Array(data.prefix(Self.headerSize)) }
    public var image: Data { data.dropFirst(Self.headerSize) }
    public var loadAddress: UInt32 { readLE32(header, 0x04) }
    public var imageLength: UInt32 { readLE32(header, 0x08) }
    public var imageChecksum: UInt32 { readLE32(header, 0x0C) }
    public var headerChecksum: UInt32 { readLE32(header, 0x58) }
    public var identity: IdentityBlock { IdentityBlock(Array(header[0x10..<0x58]))! }
    public var version: Version { identity.software }
    public var model: String { identity.model }

    /// Everything the official updater checks, plus a sanity check of the vector table.
    public static func problems(in data: Data) -> [String] {
        guard data.count > headerSize else { return ["the file is too short to be firmware"] }
        let h = Array(data.prefix(headerSize))
        var p: [String] = []
        if readLE32(h, 0x10) != IdentityBlock.magic { p.append("the identity magic is missing") }
        if Checksum.sum32(h[0..<0x58]) != readLE32(h, 0x58) { p.append("the header checksum is wrong") }
        if readLE32(h, 0x04) != requiredLoadAddress {
            p.append(String(format: "the load address is 0x%08X, expected 0x%08X", readLE32(h, 0x04), requiredLoadAddress))
        }
        let len = Int(readLE32(h, 0x08))
        let body = data.dropFirst(headerSize)
        if len == 0 || len % 16 != 0 { p.append("the image length \(len) is not a non-zero multiple of 16") }
        if body.count != len { p.append("the image is \(body.count) bytes but the header says \(len)") }
        if Checksum.sum32(body) != readLE32(h, 0x0C) { p.append("the image checksum is wrong") }
        if body.count >= 8 {
            let b = Array(body.prefix(8))
            let sp = readLE32(b, 0), reset = readLE32(b, 4)
            let end = UInt64(requiredLoadAddress) + UInt64(body.count)
            if sp & 0xFFF0_0000 != 0x2000_0000 { p.append(String(format: "the initial stack pointer 0x%08X is not in RAM", sp)) }
            if reset & 1 == 0 || UInt64(reset) < UInt64(requiredLoadAddress) || UInt64(reset) >= end {
                p.append(String(format: "the reset vector 0x%08X is not inside the image", reset))
            }
        }
        return p
    }

    public init(data: Data) throws {
        let p = Self.problems(in: data)
        guard p.isEmpty else { throw CayoteError.badFirmware(p.joined(separator: "; ")) }
        self.data = Data(data)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// Build a valid file around an image (used by the simulator and tests).
    public static func build(image: Data, identity: IdentityBlock, loadAddress: UInt32 = requiredLoadAddress) -> Data {
        var h = [UInt8](repeating: 0, count: headerSize)
        h.replaceSubrange(4..<8, with: le32(loadAddress))
        h.replaceSubrange(8..<12, with: le32(UInt32(image.count)))
        h.replaceSubrange(12..<16, with: le32(Checksum.sum32(image)))
        h.replaceSubrange(0x10..<0x58, with: identity.bytes)
        h.replaceSubrange(0x58..<0x5C, with: le32(Checksum.sum32(h[0..<0x58])))
        return Data(h) + image
    }

    public var summary: String {
        String(format: "%@ firmware %@ (hardware %d.%d, %d bytes at 0x%08X, checksum 0x%08X)",
               model, version.description, identity.hardware.major, identity.hardware.minor,
               Int(imageLength), loadAddress, imageChecksum)
    }
}

public enum CayoteError: Error, CustomStringConvertible, Equatable {
    case noDevice
    case openFailed(String)
    case ioFailed(String)
    case timeout(String)
    case unexpected(String)
    case badFirmware(String)
    case notInUpdateMode
    case inUpdateMode
    case wrongCharger(String)
    case failed(String)
    case cancelled

    public var description: String {
        switch self {
        case .noDevice:
            return "No Cayote charger found. Connect the USB-C Upgrade Port on the back of the charger "
                + "(not the front USB-C power port) to the Mac with the upgrade cable from the box."
        case let .openFailed(m): return "Could not open the charger: \(m)"
        case let .ioFailed(m): return "USB communication failed: \(m)"
        case let .timeout(m): return "The charger did not answer (\(m))."
        case let .unexpected(m): return "Unexpected reply from the charger: \(m)"
        case let .badFirmware(m): return "Not a usable firmware file: \(m)"
        case .notInUpdateMode:
            return "The charger is running its normal firmware, not waiting for an update. Unplug the "
                + "upgrade cable from the Mac, hold UP on the charger, plug the cable back in, and release "
                + "UP when the charger beeps three times."
        case .inUpdateMode:
            return "The charger is in update mode, so it can't report its normal firmware details. Install "
                + "firmware, or power-cycle the charger without holding UP."
        case let .wrongCharger(m): return "This firmware does not fit the charger: \(m)"
        case let .failed(m): return m
        case .cancelled: return "Cancelled."
        }
    }
}
