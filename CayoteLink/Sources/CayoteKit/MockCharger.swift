import Foundation

/// A simulated charger: the normal firmware's Identify/0x21/0x22 and a bootloader that
/// erases and writes flash with NOR semantics (writing can only clear bits).
/// Everything about the bootloader beyond what the official updater expects is an assumption.
public final class MockCharger: ChargerTransport {
    public enum Mode: Equatable { case normal, update }

    public static let flashBase: UInt32 = 0x0800_4000
    public static let flashSize = 0x7C000 // up to 0x08080000 (512 KB part)

    public private(set) var mode: Mode
    public private(set) var flash: [UInt8]
    public private(set) var log: [String] = []
    public var bootloaderIdentity: IdentityBlock
    public let chipID: [UInt8] = (0..<12).map { UInt8(0x30 + $0) }

    // Fault injection for tests.
    /// Stop answering after this many writes (simulates an unplugged cable).
    public var dropAfterWrites: Int?
    /// Answer the final check with failure.
    public var failCheck = false
    /// Answer writes after this count with an error code.
    public var refuseWriteAt: Int?
    /// Pretend erasing takes this long (seconds).
    public var eraseDelay: TimeInterval = 0

    public private(set) var writeCount = 0
    public private(set) var eraseCount = 0
    private var erasedRange: Range<Int>?
    private var parser = FrameParser(expectedSource: Frame.hostAddress)
    private var outbox: [Data] = []
    private var closed = false

    /// - Parameter firmware: what is installed now (nil = empty flash, so update mode).
    public init(firmware: FirmwareFile?, mode: Mode = .normal) {
        flash = [UInt8](repeating: 0xFF, count: Self.flashSize)
        bootloaderIdentity = IdentityBlock.make(vendor: "The GREPOW CO.,LTD", model: "Cayote D700",
                                                hardware: Version(1, 0, 0), software: Version(1, 0, 0))
        if let fw = firmware {
            let img = [UInt8](fw.image)
            flash.replaceSubrange(0..<img.count, with: img)
            // Real bootloader (2026-11-16): hardware 1.0.1, bootloader 1.0.0.
            bootloaderIdentity = IdentityBlock.make(vendor: fw.identity.vendor, model: fw.identity.model,
                                                    hardware: Version(fw.identity.hardware.major, fw.identity.hardware.minor, 1),
                                                    software: Version(fw.identity.software.major, 0, 0))
        }
        self.mode = firmware == nil ? .update : mode
    }

    /// The identity block of the installed application, found through vector-table slot 13 (0x34).
    public var applicationIdentity: IdentityBlock? {
        let ptr = readLE32(flash, 0x34)
        guard ptr >= Self.flashBase, Int(ptr - Self.flashBase) + IdentityBlock.size <= flash.count else { return nil }
        let o = Int(ptr - Self.flashBase)
        let block = IdentityBlock(Array(flash[o..<(o + IdentityBlock.size)]))
        return block?.hasMagic == true ? block : nil
    }

    /// Does the flash hold a plausible application?
    public var applicationLooksValid: Bool {
        let sp = readLE32(flash, 0), reset = readLE32(flash, 4)
        return sp & 0xFFF0_0000 == 0x2000_0000 && reset & 1 == 1
            && reset >= Self.flashBase && reset < Self.flashBase + UInt32(Self.flashSize)
            && applicationIdentity != nil
    }

    public func image(length: Int) -> Data { Data(flash.prefix(length)) }

    /// Power-cycle; with `holdingUp` the bootloader stays in update mode.
    public func powerCycle(holdingUp: Bool = false) {
        mode = holdingUp || !applicationLooksValid ? .update : .normal
        parser.reset()
        outbox = []
    }

    // MARK: ChargerTransport

    public func write(report: Data) throws {
        guard !closed else { throw CayoteError.ioFailed("closed") }
        precondition(report.count == 64, "reports are 64 bytes")
        for frame in parser.feed(report) {
            handle(frame.payload)
        }
    }

    public func read(timeout: TimeInterval) throws -> Data? {
        if outbox.isEmpty {
            // Don't actually sleep for long timeouts in tests.
            Thread.sleep(forTimeInterval: min(timeout, 0.001))
            return nil
        }
        return outbox.removeFirst()
    }

    public func close() { closed = true }

    // MARK: Device behaviour

    private func reply(_ payload: [UInt8]) {
        outbox += Frame.reports(Frame.reply(payload))
    }

    private func identifyPayload() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 0x5C)
        p[0] = Command.identify.rawValue
        p[1] = 6
        p[2] = 2
        p[3] = mode == .update ? 1 : 0
        // Seen on hardware: in update mode the bootloader reports its own identity block.
        let id = mode == .update ? bootloaderIdentity : (applicationIdentity ?? bootloaderIdentity)
        if mode == .normal {
            let b = bootloaderIdentity.bytes
            p[4] = b[0x46]; p[5] = b[0x47]; p[6] = b[0x43]; p[7] = b[0x42]
        }
        p.replaceSubrange(0x14..<0x5C, with: id.bytes)
        p.replaceSubrange(0x0C..<0x18, with: chipID)
        return p
    }

    private func handle(_ payload: [UInt8]) {
        guard let cmd = payload.first else { return }
        log.append(String(format: "%@ 0x%02X (%d bytes)", mode == .normal ? "normal" : "update", cmd, payload.count))
        if let limit = dropAfterWrites, writeCount >= limit { return } // "unplugged"

        switch (mode, cmd) {
        case (_, Command.identify.rawValue):
            reply(identifyPayload())

        case (.normal, Command.run.rawValue):
            reply([0x21, 1])
        case (.normal, Command.rebootToUpdateMode.rawValue):
            reply([0x22, 0])
            mode = .update
            parser.reset()
        case (.normal, _):
            reply([cmd | 0x80])

        case (.update, Command.erase.rawValue):
            guard payload.count >= 12 else { reply([cmd | 0x80]); return }
            let addr = readLE32(payload, 4), len = Int(readLE32(payload, 8))
            guard addr == Self.flashBase, len > 0, len <= Self.flashSize else { reply([cmd | 0x80]); return }
            if eraseDelay > 0 { Thread.sleep(forTimeInterval: eraseDelay) }
            // Whole pages (2 KB) are erased.
            let end = min(Self.flashSize, (len + 0x7FF) & ~0x7FF)
            for i in 0..<end { flash[i] = 0xFF }
            erasedRange = 0..<end
            eraseCount += 1
            reply([cmd])

        case (.update, Command.write.rawValue):
            writeCount += 1
            if let at = refuseWriteAt, writeCount >= at { reply([cmd | 0x80]); return }
            guard payload.count == 12 + ChargerLink.chunkSize else { reply([cmd | 0x80]); return }
            let addr = readLE32(payload, 4), n = Int(readLE32(payload, 8))
            guard addr >= Self.flashBase, n > 0, n <= ChargerLink.chunkSize, let erased = erasedRange else {
                reply([cmd | 0x80]); return
            }
            let o = Int(addr - Self.flashBase)
            guard erased.contains(o), o + n <= erased.upperBound else { reply([cmd | 0x80]); return }
            // Writing over unerased flash is a host bug: refuse it like a real flash controller would.
            guard flash[o..<(o + n)].allSatisfy({ $0 == 0xFF }) else { reply([cmd | 0x80]); return }
            for i in 0..<n { flash[o + i] &= payload[12 + i] }
            reply([cmd])

        case (.update, Command.check.rawValue):
            guard payload.count >= 12 else { reply([cmd | 0x80]); return }
            let ok = !failCheck && readLE32(payload, 4) == Self.flashBase && applicationLooksValid
            reply([ok ? cmd : cmd | 0x80])

        case (.update, Command.run.rawValue):
            reply([cmd])
            if applicationLooksValid { mode = .normal }

        default:
            reply([cmd | 0x80])
        }
    }
}
