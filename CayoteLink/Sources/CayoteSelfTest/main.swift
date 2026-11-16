import Foundation
import CayoteKit

// Self-tests (no XCTest on the Command Line Tools). Usage: CayoteSelfTest [samples-dir]
// With real files in samples/firmware/ (Cayote's .7z), more checks run.

setvbuf(stdout, nil, _IOLBF, 0)
var passed = 0, failed = 0, skipped = 0

func check(_ name: String, _ cond: @autoclosure () throws -> Bool) {
    do {
        if try cond() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    } catch {
        failed += 1; print("FAIL: \(name) – threw \(error)")
    }
}

func expectError(_ name: String, _ match: (CayoteError) -> Bool, _ body: () throws -> Void) {
    do {
        try body()
        failed += 1; print("FAIL: \(name) – no error")
    } catch let e as CayoteError {
        if match(e) { passed += 1 } else { failed += 1; print("FAIL: \(name) – wrong error: \(e)") }
    } catch {
        failed += 1; print("FAIL: \(name) – unexpected error \(error)")
    }
}

func skip(_ name: String) { skipped += 1; print("skip: \(name)") }

// MARK: Frames

do {
    let hello = Frame.request([0x20])
    check("hello frame bytes", hello == [0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0x11, 0x20, 0x01, 0x20, 0x52, 0x00])
    check("reply addresses", Array(Frame.reply([0x20]).dropFirst(5).prefix(2)) == [0x20, 0x11])

    // Stuffing: four A5 in a row get a CC after them.
    let f = Frame.request([0xA5, 0xA5, 0xA5, 0xA5, 0x01])
    check("stuffing inserted", Array(f[8..<13]) == [0xA5, 0xA5, 0xA5, 0xA5, 0xCC])
    let f3 = Frame.request([0xA5, 0xA5, 0xA5, 0x01])
    check("no stuffing after three", !f3.dropFirst(5).contains(0xCC))
    // Eight A5 → two stuffing bytes.
    let f8 = Frame.request([UInt8](repeating: 0xA5, count: 8))
    check("two stuffing bytes for eight A5", f8.dropFirst(5).filter { $0 == 0xCC }.count == 2)

    // Round trips, including nasty payloads, split across 64-byte reports with padding.
    var rng = SystemRandomNumberGenerator()
    var allOK = true
    for trial in 0..<500 {
        let n = trial == 0 ? 255 : Int.random(in: 1...255, using: &rng)
        let payload: [UInt8] = (0..<n).map { _ in
            Bool.random(using: &rng) ? 0xA5 : (Bool.random(using: &rng) ? 0xCC : UInt8.random(in: 0...255, using: &rng))
        }
        var parser = FrameParser(expectedSource: Frame.hostAddress)
        var got: [ReceivedFrame] = []
        for r in Frame.reports(Frame.request(payload)) { got += parser.feed(r) }
        if got.count != 1 || got[0].payload != payload || got[0].dst != Frame.chargerAddress { allOK = false; break }
    }
    check("500 random frames survive stuffing and report splitting", allOK)

    // The charger's parser rejects frames from the wrong source and with bad checksums.
    var p = FrameParser(expectedSource: Frame.chargerAddress)
    check("wrong source ignored", p.feed(Data(Frame.request([0x20]))).isEmpty)
    var bad = Frame.reply([0x20, 1, 2])
    bad[bad.count - 2] ^= 1
    p.reset()
    check("bad checksum ignored", p.feed(Data(bad)).isEmpty)
    p.reset()
    check("two frames in one report", p.feed(Data(Frame.reply([0x30]) + Frame.reply([0x32]))).map { $0.payload } == [[0x30], [0x32]])
    check("reports are 64 bytes", Frame.reports(Frame.request([UInt8](repeating: 1, count: 200))).allSatisfy { $0.count == 64 })
}

// MARK: Checksums and versions

check("sum32 words", Checksum.sum32([1, 0, 0, 0, 2, 0, 0, 0]) == 3)
check("sum32 tail 1", Checksum.sum32([0, 0, 0, 0, 7]) == 7)
check("sum32 tail 3", Checksum.sum32([1, 2, 3]) == 0x030201)
check("sum32 wraps", Checksum.sum32([0xFF, 0xFF, 0xFF, 0xFF, 2, 0, 0, 0]) == 1)
check("version parse", Version("V1.2.9") == Version(1, 2, 9))
check("version order", Version(1, 2, 10) > Version(1, 2, 9) && Version(1, 3, 0) > Version(1, 2, 99))
check("version reject", Version("1.2") == nil)

// MARK: Synthetic firmware

func syntheticImage(software: Version, model: String = "Cayote D700", hardware: Version = Version(1, 0, 0),
                    size: Int = 0x4000) -> (Data, IdentityBlock) {
    var img = [UInt8](repeating: 0, count: size)
    for i in 0..<size { img[i] = UInt8((i * 7 + software.patch) & 0xFF) }
    // Vector table: SP, reset, slot 13 → identity block near the end.
    img.replaceSubrange(0..<4, with: [0x18, 0xBC, 0x00, 0x20])
    let reset: UInt32 = 0x0800_4000 + 0x101
    img.replaceSubrange(4..<8, with: [UInt8(reset & 0xFF), UInt8((reset >> 8) & 0xFF), UInt8((reset >> 16) & 0xFF), UInt8(reset >> 24)])
    let idOff = size - 0x100
    let idAddr = UInt32(0x0800_4000 + idOff)
    img.replaceSubrange(0x34..<0x38, with: [UInt8(idAddr & 0xFF), UInt8((idAddr >> 8) & 0xFF), UInt8((idAddr >> 16) & 0xFF), UInt8(idAddr >> 24)])
    let id = IdentityBlock.make(vendor: "The GREPOW CO.,LTD", model: model, hardware: hardware, software: software)
    img.replaceSubrange(idOff..<(idOff + IdentityBlock.size), with: id.bytes)
    return (Data(img), id)
}

func synthetic(_ v: Version, model: String = "Cayote D700", hardware: Version = Version(1, 0, 0)) -> FirmwareFile {
    let (img, id) = syntheticImage(software: v, model: model, hardware: hardware)
    return try! FirmwareFile(data: FirmwareFile.build(image: img, identity: id))
}

let fwOld = synthetic(Version(1, 2, 8))
let fwNew = synthetic(Version(1, 2, 9))
check("synthetic file valid", fwNew.version == Version(1, 2, 9) && fwNew.model == "Cayote D700")

do {
    var d = [UInt8](fwNew.data)
    d[0x200] ^= 0x10
    check("image corruption detected", FirmwareFile.problems(in: Data(d)).contains { $0.contains("image checksum") })
    d = [UInt8](fwNew.data)
    d[0x3C] = 0x58 // model name in header
    check("header corruption detected", FirmwareFile.problems(in: Data(d)).contains { $0.contains("header checksum") })
    let moved = FirmwareFile.build(image: fwNew.image, identity: fwNew.identity, loadAddress: 0x0800_0000)
    check("bootloader address refused", FirmwareFile.problems(in: moved).contains { $0.contains("load address") })
    check("truncated refused", !FirmwareFile.problems(in: fwNew.data.dropLast(16)).isEmpty)
    check("odd length refused", !FirmwareFile.problems(in: FirmwareFile.build(image: fwNew.image + Data([0]), identity: fwNew.identity)).isEmpty)
    check("embedded file found", UpdaterPackage.firmwareFiles(in: Data(repeating: 0x5A, count: 1000) + fwNew.data + Data(count: 77)).map(\.data) == [fwNew.data])
    check("nothing found in noise", UpdaterPackage.firmwareFiles(in: Data((0..<5000).map { UInt8($0 & 0xFF) })).isEmpty)
}

// MARK: Identity check (as the official updater)

do {
    let charger = fwOld.identity
    check("same model, minor update accepted", fwNew.identity.accepts(charger: charger))
    check("other model refused", !synthetic(Version(1, 2, 9), model: "Cayote D800").identity.accepts(charger: charger))
    check("other hardware refused", !synthetic(Version(1, 2, 9), hardware: Version(2, 0, 0)).identity.accepts(charger: charger))
    check("major firmware change refused", !synthetic(Version(2, 0, 0)).identity.accepts(charger: charger))
    check("hardware patch ignored", synthetic(Version(1, 2, 9), hardware: Version(1, 0, 5)).identity.accepts(charger: charger))
    let g6 = synthetic(Version(1, 0, 0), model: "G6 Devices", hardware: Version(1, 0, 0))
    let g6Charger = IdentityBlock.make(vendor: "The GREPOW CO.,LTD", model: "G6 Pro", hardware: Version(1, 0, 0), software: Version(1, 0, 0))
    check("G6 Devices file accepts G6 Pro", g6.identity.accepts(charger: g6Charger))
    check("mismatch explained", synthetic(Version(1, 2, 9), model: "Cayote D800").identity.mismatch(charger: charger)?.contains("D800") == true)
}

// MARK: Simulated charger

do {
    // Normal mode: Identify is read-only and reports the installed version.
    let mock = MockCharger(firmware: fwOld)
    let link = ChargerLink(transport: mock)
    let info = try link.identify()
    check("normal mode identify", !info.inUpdateMode && info.firmware == Version(1, 2, 8) && info.model == "Cayote D700")
    check("normal identify changed nothing", mock.image(length: fwOld.image.count) == fwOld.image && mock.eraseCount == 0)
    check("chip id reported", info.chipID == "303132333435363738393A3B")

    // The updater refuses to start outside update mode.
    expectError("install refused in normal mode", { $0 == .notInUpdateMode }) {
        try FirmwareUpdater(link: link, firmware: fwNew).preflight()
    }
    check("refusal changed nothing", mock.eraseCount == 0 && mock.writeCount == 0)

    // Wrong model refused in update mode.
    mock.powerCycle(holdingUp: true)
    expectError("wrong model refused", { if case .wrongCharger = $0 { return true } else { return false } }) {
        try FirmwareUpdater(link: link, firmware: synthetic(Version(1, 2, 9), model: "Cayote D800")).preflight()
    }

    // Full install.
    let up = FirmwareUpdater(link: link, firmware: fwNew)
    var phases: [FirmwareUpdater.Phase] = []
    up.progress = { phases.append($0) }
    let pre = try up.preflight()
    check("preflight sees update mode", pre.inUpdateMode)
    check("preflight changed nothing", mock.eraseCount == 0)
    try up.install()
    check("installed image matches", mock.image(length: fwNew.image.count) == fwNew.image)
    check("charger restarted", mock.mode == .normal)
    check("reports new version", try link.identify().firmware == Version(1, 2, 9))
    check("one erase, all writes", mock.eraseCount == 1 && mock.writeCount == (fwNew.image.count + 223) / 224)
    check("phases in order", phases.first == .identifying && phases.contains(.erasing) && phases.last == .finished)
}

do {
    // Interrupted mid-write: the charger stays in update mode and a re-run recovers.
    let mock = MockCharger(firmware: fwOld)
    mock.powerCycle(holdingUp: true)
    mock.dropAfterWrites = 20
    let link = ChargerLink(transport: mock)
    let up = FirmwareUpdater(link: link, firmware: fwNew)
    try up.preflight()
    expectError("interrupted write reported", { if case .timeout = $0 { return true } else { return false } }) {
        try up.install()
    }
    mock.dropAfterWrites = nil
    mock.powerCycle()
    check("broken firmware boots into update mode", mock.mode == .update)
    let again = FirmwareUpdater(link: ChargerLink(transport: mock), firmware: fwNew)
    try again.preflight()
    try again.install()
    check("re-run after interruption recovers", mock.image(length: fwNew.image.count) == fwNew.image && mock.mode == .normal)
}

do {
    let mock = MockCharger(firmware: fwOld)
    mock.powerCycle(holdingUp: true)
    mock.failCheck = true
    let up = FirmwareUpdater(link: ChargerLink(transport: mock), firmware: fwNew)
    try up.preflight()
    expectError("failed check reported", { if case .failed = $0 { return true } else { return false } }) { try up.install() }
    check("failed check leaves update mode on", mock.mode == .update)

    let mock2 = MockCharger(firmware: fwOld)
    mock2.powerCycle(holdingUp: true)
    mock2.refuseWriteAt = 5
    let up2 = FirmwareUpdater(link: ChargerLink(transport: mock2), firmware: fwNew)
    try up2.preflight()
    expectError("refused write reported", { if case .failed = $0 { return true } else { return false } }) { try up2.install() }

    // 0x22 puts the simulated charger into update mode.
    let mock3 = MockCharger(firmware: fwOld)
    let l3 = ChargerLink(transport: mock3)
    try l3.rebootToUpdateMode()
    let afterReboot = try l3.identify()
    check("0x22 enters update mode", mock3.mode == .update && afterReboot.inUpdateMode)

    // Empty flash: the bootloader answers with its own identity, which must still be accepted.
    let blank = MockCharger(firmware: nil)
    let up4 = FirmwareUpdater(link: ChargerLink(transport: blank), firmware: fwNew)
    try up4.preflight()
    try up4.install()
    check("install onto empty flash", blank.mode == .normal)
} catch {
    failed += 1
    print("FAIL: simulator flows threw \(error)")
}

// MARK: Update check

do {
    let html = """
    <a href="https://cayote.com/wp-content/uploads/2026/08/manual.pdf#view=FitH">Download</a>
    <a class="x" href="https://cayote.com/wp-content/uploads/2026/11/Cayote-2-Force-X5-V1.2.9-4.7z">Download</a>
    <a href='/wp-content/uploads/2026/01/Cayote-2-Force-X5-V1.2.10.7z'>old link</a>
    <a href="http://evil.example/Cayote-2-Force-X5-V9.9.9.7z">plain http</a>
    """
    let r = UpdateCheck.releases(inHTML: html)
    check("releases found, newest first", r.map(\.label) == ["V1.2.10", "V1.2.9-4"])
    check("relative link resolved", r.first?.url.absoluteString == "https://cayote.com/wp-content/uploads/2026/01/Cayote-2-Force-X5-V1.2.10.7z")
    check("plain http ignored", !r.contains { $0.version == Version(9, 9, 9) })
}

// MARK: Real files

let samples = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../samples")
let fwDir = samples.appendingPathComponent("firmware")
let archives = ((try? FileManager.default.contentsOfDirectory(at: fwDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { ["7z", "exe", "grp"].contains($0.pathExtension.lowercased()) }
if archives.isEmpty {
    skip("real firmware files (put Cayote's .7z in \(fwDir.path))")
}
for a in archives {
    do {
        let fw = try UpdaterPackage.load(a)
        check("\(a.lastPathComponent): model", fw.model == "Cayote D700")
        check("\(a.lastPathComponent): load address", fw.loadAddress == 0x0800_4000)
        check("\(a.lastPathComponent): identity block also inside the image", fw.image.range(of: Data(fw.identity.bytes)) != nil)
        let ptr = fw.image.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0x34, as: UInt32.self) }
        let off = Int(ptr) - 0x0800_4000
        check("\(a.lastPathComponent): vector slot 13 points at the identity block",
              off >= 0 && off + IdentityBlock.size <= fw.image.count
                && Array(fw.image[(fw.image.startIndex + off)..<(fw.image.startIndex + off + IdentityBlock.size)]) == fw.identity.bytes)
        if a.lastPathComponent.contains("V1.2.9") {
            check("\(a.lastPathComponent): version 1.2.9", fw.version == Version(1, 2, 9))
            check("\(a.lastPathComponent): image checksum", fw.imageChecksum == 0x803B_4C46 && fw.imageLength == 0x6CA30)
        }
        // Full simulated install of the real image.
        let mock = MockCharger(firmware: fwOld)
        mock.powerCycle(holdingUp: true)
        let up = FirmwareUpdater(link: ChargerLink(transport: mock), firmware: fw)
        try up.preflight()
        try up.install()
        check("\(a.lastPathComponent): simulated install", mock.image(length: fw.image.count) == fw.image && mock.mode == .normal)
        check("\(a.lastPathComponent): simulator reads the version back", try ChargerLink(transport: mock).identify().firmware == fw.version)
    } catch {
        failed += 1
        print("FAIL: \(a.lastPathComponent) threw \(error)")
    }
}

print("\(passed) passed, \(failed) failed, \(skipped) skipped")
exit(failed == 0 ? 0 : 1)
