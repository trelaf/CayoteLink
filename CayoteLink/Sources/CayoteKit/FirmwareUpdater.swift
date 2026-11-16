import Foundation

/// The firmware update, step for step as the official updater does it
/// (docs/PROTOCOL.md §3), split so nothing is erased before the caller has confirmed.
public final class FirmwareUpdater {
    public enum Phase: Equatable, Sendable {
        case identifying
        case erasing
        case writing(done: Int, total: Int)
        case checking
        case starting
        case finished
    }

    public let link: ChargerLink
    public let firmware: FirmwareFile
    /// Called from the updating thread.
    public var progress: ((Phase) -> Void)?
    /// Bytes per second assumed for estimates; filled in after an install.
    public private(set) var elapsed: TimeInterval = 0

    public init(link: ChargerLink, firmware: FirmwareFile) {
        self.link = link
        self.firmware = firmware
    }

    /// Read-only: confirm the charger is in update mode and that the file fits it.
    /// This is what `rehearse` / `probe` run; nothing is changed on the charger.
    @discardableResult
    public func preflight() throws -> ChargerInfo {
        progress?(.identifying)
        try? link.drain()
        let info = try link.identify(tries: 3, timeout: 1.0)
        guard info.inUpdateMode else { throw CayoteError.notInUpdateMode }
        guard let id = info.identity else {
            throw CayoteError.unexpected("the Identify reply has no identity block (\(info.payload.count) bytes)")
        }
        if let why = firmware.identity.mismatch(charger: id) { throw CayoteError.wrongCharger(why) }
        return info
    }

    /// Erase, write, check and start. Call only after `preflight()` succeeded and the user confirmed.
    public func install() throws {
        let start = Date()
        let base = firmware.loadAddress
        let image = firmware.image
        let total = image.count

        progress?(.erasing)
        try link.erase(address: base, length: UInt32(total), timeout: 15)

        var offset = 0
        var timeout: TimeInterval = 10 // the first write may wait for the erase to finish
        progress?(.writing(done: 0, total: total))
        while offset < total {
            let n = min(ChargerLink.chunkSize, total - offset)
            let chunk = image.subdata(in: (image.startIndex + offset)..<(image.startIndex + offset + n))
            try link.write(address: base + UInt32(offset), chunk: chunk, timeout: timeout)
            timeout = 5
            offset += n
            progress?(.writing(done: offset, total: total))
        }

        progress?(.checking)
        try link.check(address: base, length: UInt32(total), timeout: 2)

        progress?(.starting)
        try link.run()
        elapsed = Date().timeIntervalSince(start)
        progress?(.finished)
    }
}
