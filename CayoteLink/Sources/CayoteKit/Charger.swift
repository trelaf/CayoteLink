import Foundation

/// Raw 64-byte report pipe. `HIDTransport` talks to a real charger, `MockCharger` simulates one.
public protocol ChargerTransport: AnyObject {
    /// Send one 64-byte output report (no report-ID prefix).
    func write(report: Data) throws
    /// Wait for the next input report; nil on timeout.
    func read(timeout: TimeInterval) throws -> Data?
    func close()
}

public enum Command: UInt8, Sendable {
    case identify = 0x20
    case run = 0x21
    case rebootToUpdateMode = 0x22
    case erase = 0x30
    case write = 0x32
    case check = 0x33
}

/// The charger's answer to Identify (0x20), docs/PROTOCOL.md §4.
public struct ChargerInfo: Equatable, Sendable {
    public var payload: [UInt8]

    public init?(payload: [UInt8]) {
        guard payload.first == Command.identify.rawValue, payload.count >= 4 else { return nil }
        self.payload = payload
    }

    /// payload[3] != 0: the bootloader is answering (update mode). The updater requires this.
    public var inUpdateMode: Bool { payload[3] != 0 }
    /// The identity block at payload offset 0x14 (first 4 bytes overwritten by the chip ID).
    public var identity: IdentityBlock? {
        payload.count >= 0x14 + IdentityBlock.size ? IdentityBlock(Array(payload[0x14..<(0x14 + IdentityBlock.size)])) : nil
    }
    public var model: String? { identity?.model }
    /// The identity's software version: the installed firmware in normal mode,
    /// the bootloader's own version in update mode.
    public var firmware: Version? { identity?.software }
    public var hardware: Version? { identity?.hardware }

    /// The hardware revision as far as this reply knows it. In update mode the bootloader
    /// reports the board's real revision (e.g. 1.0.1, as About Device shows). In normal mode
    /// the reply only carries the firmware's own block, whose hardware patch is just the build
    /// target, so only "major.minor" is meaningful there [hw 2026-11-16].
    public var hardwareDescription: String? {
        guard let h = hardware else { return nil }
        return inUpdateMode ? h.description : "\(h.major).\(h.minor)"
    }

    /// One line for logs.
    public var oneLine: String {
        let m = model ?? "?"
        if inUpdateMode {
            return "\(m) in update mode (bootloader \(firmware?.description ?? "?"), hardware \(hardwareDescription ?? "?"))"
        }
        return "\(m), firmware \(firmware?.description ?? "?"), hardware \(hardwareDescription ?? "?")"
    }
    /// 96-bit chip unique ID, as hex.
    public var chipID: String? {
        payload.count >= 0x18 ? payload[0x0C..<0x18].map { String(format: "%02X", $0) }.joined() : nil
    }
    /// The bootloader identity's software version, reported by the normal firmware at 0x04–0x07.
    public var bootloaderVersion: Version? {
        payload.count >= 8 ? Version(Int(payload[7]), Int(payload[6]), Int(readLE16(payload, 4))) : nil
    }

    public var summary: String {
        var lines: [String] = []
        lines.append("Mode:        " + (inUpdateMode ? "update mode (bootloader)" : "normal"))
        if let m = model { lines.append("Model:       \(m)") }
        if let v = identity?.vendor, !v.isEmpty { lines.append("Maker:       \(v)") }
        if inUpdateMode {
            // In update mode the bootloader answers with its own identity block [hw 2026-11-16].
            if let f = firmware { lines.append("Bootloader:  \(f)") }
            lines.append("Firmware:    (not reported in update mode – see About Device on the charger)")
        } else {
            if let f = firmware { lines.append("Firmware:    \(f)") }
            if let b = bootloaderVersion { lines.append("Bootloader:  \(b)") }
        }
        if let h = hardwareDescription { lines.append("Hardware:    \(h)") }
        if let c = chipID { lines.append("Chip ID:     \(c)") }
        return lines.joined(separator: "\n")
    }
}

/// Request/reply over a transport.
public final class ChargerLink {
    public let transport: ChargerTransport
    private var parser = FrameParser(expectedSource: Frame.chargerAddress)
    /// Called with every frame sent and received (for logs and --trace).
    public var trace: ((String) -> Void)?

    public init(transport: ChargerTransport) {
        self.transport = transport
    }

    public func close() { transport.close() }

    public func send(_ payload: [UInt8]) throws {
        let stream = Frame.request(payload)
        trace?("→ " + Array(payload.prefix(16)).hex + (payload.count > 16 ? " … (\(payload.count) bytes)" : ""))
        for report in Frame.reports(stream) {
            try transport.write(report: report)
        }
    }

    private var pending: [ReceivedFrame] = []

    /// Wait for the next complete frame from the charger.
    public func receive(timeout: TimeInterval) throws -> ReceivedFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while pending.isEmpty {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            guard let report = try transport.read(timeout: left) else { return nil }
            pending += parser.feed(report)
        }
        let f = pending.removeFirst()
        trace?("← " + Array(f.payload.prefix(16)).hex + (f.payload.count > 16 ? " … (\(f.payload.count) bytes)" : ""))
        return f
    }

    /// Discard anything received so far.
    public func drain() throws {
        pending = []
        parser.reset()
        while try transport.read(timeout: 0.05) != nil {}
    }

    /// Send a request and wait for a reply. Replies to other commands are skipped.
    public func transact(_ payload: [UInt8], timeout: TimeInterval) throws -> ReceivedFrame? {
        pending = []
        parser.reset()
        try send(payload)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            guard let f = try receive(timeout: left) else { return nil }
            guard let cmd = f.command else { continue }
            if cmd == payload[0] || cmd == payload[0] | 0x80 { return f }
        }
    }

    // MARK: Commands

    /// Identify (0x20). Read-only in both normal and update mode.
    public func identify(tries: Int = 3, timeout: TimeInterval = 1.0) throws -> ChargerInfo {
        for _ in 0..<max(1, tries) {
            if let f = try transact([Command.identify.rawValue], timeout: timeout), let info = ChargerInfo(payload: f.payload) {
                return info
            }
        }
        throw CayoteError.timeout("no answer to Identify")
    }

    private func addressed(_ cmd: Command, address: UInt32, length: UInt32) -> [UInt8] {
        [cmd.rawValue, 0, 0, 0] + le32(address) + le32(length)
    }

    private func expect(_ f: ReceivedFrame?, _ cmd: Command, _ what: String) throws {
        guard let f else { throw CayoteError.timeout("no answer to \(what)") }
        guard f.command == cmd.rawValue else {
            throw CayoteError.failed(String(format: "The charger refused %@ (answer 0x%02X).", what, f.command ?? 0))
        }
    }

    /// Erase (0x30). The charger may take several seconds.
    public func erase(address: UInt32, length: UInt32, timeout: TimeInterval = 15) throws {
        try expect(try transact(addressed(.erase, address: address, length: length), timeout: timeout), .erase, "erase")
    }

    public static let chunkSize = 224

    /// Write (0x32): up to 224 bytes; the payload is always 236 bytes long.
    public func write(address: UInt32, chunk: Data, timeout: TimeInterval) throws {
        precondition(chunk.count <= Self.chunkSize && !chunk.isEmpty)
        var p = addressed(.write, address: address, length: UInt32(chunk.count))
        p += chunk
        p += [UInt8](repeating: 0xFF, count: Self.chunkSize - chunk.count)
        try expect(try transact(p, timeout: timeout), .write, String(format: "the write at 0x%08X", address))
    }

    /// Check (0x33): the charger verifies the written image.
    public func check(address: UInt32, length: UInt32, timeout: TimeInterval = 2) throws {
        try expect(try transact(addressed(.check, address: address, length: length), timeout: timeout), .check, "the final check")
    }

    /// Run (0x21): leave update mode and start the new firmware.
    public func run(tries: Int = 3, timeout: TimeInterval = 0.5) throws {
        for _ in 0..<max(1, tries) {
            if let f = try transact([Command.run.rawValue], timeout: timeout), f.command == Command.run.rawValue { return }
        }
        throw CayoteError.timeout("no answer to Run")
    }

    /// 0x22, implemented by the normal firmware but never sent by the official updater:
    /// reply, then reset into update mode. Experimental.
    public func rebootToUpdateMode(timeout: TimeInterval = 1) throws {
        try expect(try transact([Command.rebootToUpdateMode.rawValue], timeout: timeout), .rebootToUpdateMode, "the reboot")
    }
}
