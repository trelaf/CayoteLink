import Foundation
import CayoteKit

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
cayote – Cayote 2-Force X5 charger tool (firmware check and update)

  cayote info                    show the connected charger's model and firmware (read-only)
  cayote devices                 list matching USB devices
  cayote check-updates           compare with the newest firmware on cayote.com
  cayote download [-o DIR]       download the newest updater (.7z)
  cayote inspect FILE            check a .7z, updater .exe or .grp and show its firmware
  cayote extract FILE -o OUT.grp save the firmware inside a .7z or .exe as a .grp
  cayote probe FILE              in update mode: check the charger accepts FILE (read-only)
  cayote install FILE [--yes]    in update mode: install FILE
  cayote simulate FILE           run a complete install against the built-in simulator
  cayote reboot-to-update --experimental
                                 ask the running firmware to restart in update mode
                                 (command 0x22; the official updater never uses it)

Options: --trace prints every frame.

Connect the charger's rear "USB-C Upgrade Port" (between the DC and AC inputs) with the
upgrade cable from the box; the front USB-C port only supplies power.

Update mode (manual p. 24): with the cable in the charger, hold UP, plug the USB-A end into
the Mac, and release UP after the charger beeps three times. The screen stays dark.
"""

var args = Array(CommandLine.arguments.dropFirst())
let trace = args.contains("--trace")
let assumeYes = args.contains("--yes")
let experimental = args.contains("--experimental")
args.removeAll { ["--trace", "--yes", "--experimental"].contains($0) }

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func openLink() throws -> ChargerLink {
    let t = try HIDTransport.openFirst()
    let link = ChargerLink(transport: t)
    if trace { link.trace = { print("  " + $0) } }
    return link
}

func loadFirmware(_ path: String) throws -> FirmwareFile {
    try UpdaterPackage.load(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
}

func runAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
    var result: Result<T, Error>!
    let sem = DispatchSemaphore(value: 0)
    Task {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}

func confirm(_ question: String) -> Bool {
    if assumeYes { return true }
    print(question + " Type \"yes\" to continue: ", terminator: "")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes"
}

func printProgress(_ phase: FirmwareUpdater.Phase) {
    switch phase {
    case .identifying: print("Asking the charger who it is…")
    case .erasing: print("Erasing the old firmware…")
    case let .writing(done, total):
        if done == 0 || done == total || (done / ChargerLink.chunkSize) % 100 == 0 {
            print(String(format: "Writing… %3d%%  (%d of %d bytes)", done * 100 / max(total, 1), done, total))
        }
    case .checking: print("Charger is checking the new firmware…")
    case .starting: print("Starting the new firmware…")
    case .finished: print("Done.")
    }
}

func runInstall(link: ChargerLink, firmware: FirmwareFile, dryRun: Bool) throws {
    print("File: \(firmware.summary)")
    let updater = FirmwareUpdater(link: link, firmware: firmware)
    updater.progress = printProgress
    let info = try updater.preflight()
    print(info.summary)
    print("The charger accepts this firmware.")
    if dryRun {
        print("Probe finished: nothing was changed. The charger is still in update mode; unplug it to leave.")
        return
    }
    guard confirm("Install \(firmware.model) firmware \(firmware.version)? The old firmware is erased first, "
        + "and the USB cable must stay connected until it finishes.") else {
        print("Nothing was changed.")
        return
    }
    try updater.install()
    print(String(format: "Installed firmware %@ in %.0f s. The charger restarts by itself.", firmware.version.description, updater.elapsed))
}

do {
    switch args.first ?? "help" {
    case "devices":
        let d = HIDTransport.connectedDevices()
        if d.isEmpty { print("No Cayote charger connected.") }
        d.forEach { print($0) }

    case "info":
        let link = try openLink()
        defer { link.close() }
        let info = try link.identify()
        print(info.summary)
        if trace {
            print("Raw Identify payload (\(info.payload.count) bytes):")
            for o in stride(from: 0, to: info.payload.count, by: 16) {
                let row = info.payload[o..<min(o + 16, info.payload.count)]
                print(String(format: "  %02X  ", o) + row.map { String(format: "%02X", $0) }.joined(separator: " "))
            }
        }
        if info.inUpdateMode {
            print("\nThe charger is in update mode. Run `cayote install FILE`, or unplug it to leave update mode.")
        }

    case "inspect":
        guard args.count >= 2 else { fail("usage: cayote inspect FILE") }
        let fw = try loadFirmware(args[1])
        print(fw.summary)
        print("Vendor: \(fw.identity.vendor)")
        print("All checks passed (header and image checksums, load address, vector table).")

    case "extract":
        guard let out = option("-o"), args.count >= 2 else { fail("usage: cayote extract FILE -o OUT.grp") }
        let fw = try loadFirmware(args[1])
        try fw.data.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
        print("Saved \(fw.summary) to \(out)")

    case "check-updates":
        let latest = try runAsync { try await UpdateCheck.latest() }
        print("Newest on cayote.com: \(latest.label)  \(latest.url.absoluteString)")
        if let link = try? openLink() {
            defer { link.close() }
            if let info = try? link.identify(), !info.inUpdateMode, let v = info.firmware {
                print("The charger has \(v): " + (v < latest.version ? "an update is available." : "it is up to date."))
            }
        } else {
            print("(Connect the charger to compare with its firmware.)")
        }

    case "download":
        let dir = option("-o").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? UpdateCheck.downloadsDirectory
        let latest = try runAsync { try await UpdateCheck.latest() }
        print("Downloading \(latest.label)…")
        let file = try runAsync { try await UpdateCheck.download(latest, to: dir) }
        let fw = try UpdaterPackage.load(file)
        print("Saved \(file.path)\n\(fw.summary)")

    case "probe", "install":
        guard args.count >= 2 else { fail("usage: cayote \(args[0]) FILE") }
        let fw = try loadFirmware(args[1])
        let link = try openLink()
        defer { link.close() }
        try runInstall(link: link, firmware: fw, dryRun: args[0] == "probe")

    case "simulate":
        guard args.count >= 2 else { fail("usage: cayote simulate FILE") }
        let fw = try loadFirmware(args[1])
        let mock = MockCharger(firmware: fw)
        mock.powerCycle(holdingUp: true)
        let link = ChargerLink(transport: mock)
        if trace { link.trace = { print("  " + $0) } }
        print("Simulated charger, in update mode.")
        let saved = assumeYes
        _ = saved
        try runInstall(link: link, firmware: fw, dryRun: false)
        let ok = mock.image(length: fw.image.count) == fw.image && mock.mode == .normal
        print(ok ? "Simulator: flash matches the file and the charger restarted." : "Simulator: MISMATCH")
        if !ok { exit(1) }

    case "reboot-to-update":
        guard experimental else {
            fail("this sends command 0x22, which the official updater never uses. Holding UP while plugging in "
                + "is the documented way. To try it anyway, add --experimental.")
        }
        let link = try openLink()
        defer { link.close() }
        let info = try link.identify()
        if info.inUpdateMode { print("Already in update mode."); break }
        try link.rebootToUpdateMode()
        print("The charger accepted the request and should now restart in update mode. Check with `cayote info`.")

    case "help", "-h", "--help":
        print(usage)

    default:
        fail("unknown command \(args[0])\n\n" + usage)
    }
} catch {
    fail("\(error)")
}
