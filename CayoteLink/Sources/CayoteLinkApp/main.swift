import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CayoteKit

// Note: no SwiftUI @State (the Command Line Tools lack the macro plugin); all view
// state lives in AppModel as @Published properties.

enum InstallPhase: Equatable {
    case idle
    case checking          // read-only identify in update mode
    case ready(String)     // charger accepted the file
    case installing
    case done(String)
    case failed(String)

    var isBusy: Bool { self == .checking || self == .installing }
}

final class AppModel: ObservableObject {
    static var current: AppModel?

    // Charger
    @Published var deviceConnected = false
    @Published var charger: ChargerInfo?
    @Published var chargerError: String?

    // Firmware
    @Published var latest: UpdateCheck.Release?
    @Published var onlineStatus = ""
    @Published var firmware: FirmwareFile?
    @Published var firmwareSource: URL?
    @Published var firmwareError: String?
    @Published var downloading = false

    // Install
    @Published var phase: InstallPhase = .idle
    @Published var progress: Double = 0
    @Published var progressText = ""
    @Published var log: [String] = []

    private let worker = DispatchQueue(label: "CayoteLink.worker")
    private var timer: Timer?
    private var lastSeen = false

    init() {
        AppModel.current = self
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
        checkForUpdates()
        // Use the newest download already on disk, if any.
        if let files = try? FileManager.default.contentsOfDirectory(at: UpdateCheck.downloadsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]),
           let newest = files.filter({ $0.pathExtension.lowercased() == "7z" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first {
            openFirmware(newest, quiet: true)
        }
    }

    func note(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
    }

    // MARK: Charger

    /// Watch for the charger appearing or disappearing; identify it when it appears.
    func poll() {
        guard !phase.isBusy else { return }
        let present = !HIDTransport.connectedDevices().isEmpty
        if present != lastSeen {
            lastSeen = present
            deviceConnected = present
            if present {
                identify()
            } else {
                charger = nil
                chargerError = nil
                if case .ready = phase { phase = .idle }
                note("Charger disconnected.")
            }
        }
    }

    func identify() {
        guard !phase.isBusy else { return }
        worker.async {
            var info: ChargerInfo?
            var err: String?
            do {
                let t = try HIDTransport.openFirst()
                defer { t.close() }
                info = try ChargerLink(transport: t).identify()
            } catch {
                err = "\(error)"
            }
            DispatchQueue.main.async {
                self.charger = info
                self.chargerError = err
                if let info {
                    self.note("Charger: " + info.oneLine)
                } else if let err {
                    self.note(err)
                }
            }
        }
    }

    // MARK: Firmware

    func checkForUpdates() {
        onlineStatus = "Checking cayote.com…"
        Task {
            do {
                let r = try await UpdateCheck.latest()
                await MainActor.run {
                    self.latest = r
                    self.onlineStatus = "Newest on cayote.com: \(r.label)"
                }
            } catch {
                await MainActor.run { self.onlineStatus = "Could not check cayote.com: \(error.localizedDescription)" }
            }
        }
    }

    func downloadLatest() {
        guard let r = latest else { return }
        downloading = true
        note("Downloading \(r.url.lastPathComponent)…")
        Task {
            do {
                let file = try await UpdateCheck.download(r, to: UpdateCheck.downloadsDirectory)
                await MainActor.run {
                    self.downloading = false
                    self.openFirmware(file)
                }
            } catch {
                await MainActor.run {
                    self.downloading = false
                    self.note("Download failed: \(error)")
                }
            }
        }
    }

    func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.message = "Choose Cayote's updater download (.7z), the updater .exe, or a .grp firmware file"
        panel.allowedContentTypes = ["7z", "exe", "grp", "zip"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { openFirmware(url) }
    }

    func openFirmware(_ url: URL, quiet: Bool = false) {
        do {
            let fw = try UpdaterPackage.load(url)
            firmware = fw
            firmwareSource = url
            firmwareError = nil
            if case .ready = phase { phase = .idle }
            if !quiet { note("Opened \(url.lastPathComponent): \(fw.summary)") }
        } catch {
            if !quiet {
                firmwareError = "\(error)"
                note("\(url.lastPathComponent): \(error)")
            }
        }
    }

    /// The charger's installed firmware (known only in normal mode).
    var installedVersion: Version? {
        guard let info = charger, !info.inUpdateMode else { return nil }
        return info.firmware
    }

    /// True when the charger already has the newest version we know of (online or the chosen file).
    var upToDate: Bool {
        guard let have = installedVersion else { return false }
        let newest = [latest?.version, firmware?.version].compactMap { $0 }.max()
        return newest.map { have >= $0 } ?? false
    }

    var comparison: String? {
        guard let have = installedVersion else { return nil }
        if upToDate {
            return latest != nil ? "Up to date – \(have) is the newest on cayote.com." : "Up to date with the chosen file."
        }
        if let l = latest, l.version > have {
            return "Version \(l.version) is available on cayote.com (the charger has \(have))."
        }
        if let fw = firmware, fw.version > have {
            return "The chosen file (\(fw.version)) is newer than the charger's \(have)."
        }
        return nil
    }

    /// The newest release is already downloaded and opened.
    var latestIsOpen: Bool {
        guard let l = latest, let src = firmwareSource else { return false }
        return src.lastPathComponent == l.url.lastPathComponent
    }

    // MARK: Install

    /// Read-only: identify in update mode and check the file fits.
    func checkCharger() {
        guard let fw = firmware, !phase.isBusy else { return }
        phase = .checking
        worker.async {
            var result: InstallPhase
            var info: ChargerInfo?
            do {
                let t = try HIDTransport.openFirst()
                defer { t.close() }
                info = try FirmwareUpdater(link: ChargerLink(transport: t), firmware: fw).preflight()
                result = .ready("The charger is in update mode and accepts \(fw.model) firmware \(fw.version).")
            } catch {
                result = .failed("\(error)")
            }
            DispatchQueue.main.async {
                if let info { self.charger = info }
                self.phase = result
                if case let .ready(m) = result { self.note(m) }
                if case let .failed(m) = result { self.note(m) }
            }
        }
    }

    func install() {
        guard let fw = firmware, case .ready = phase else { return }
        let alert = NSAlert()
        alert.messageText = "Install firmware \(fw.version)?"
        alert.informativeText = "The charger's current firmware is erased first. Keep the USB cable connected and "
            + "the Mac awake until it finishes (about a minute). If it is interrupted, put the charger back "
            + "in update mode and install again."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        phase = .installing
        progress = 0
        progressText = "Starting…"
        note("Installing \(fw.summary)")
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Writing charger firmware")
        worker.async {
            var result: InstallPhase
            do {
                let t = try HIDTransport.openFirst()
                defer { t.close() }
                let up = FirmwareUpdater(link: ChargerLink(transport: t), firmware: fw)
                up.progress = { p in
                    DispatchQueue.main.async { self.show(p) }
                }
                try up.preflight() // the charger may have been swapped since the check
                try up.install()
                result = .done(String(format: "Firmware %@ installed in %.0f s. The charger restarts by itself.",
                                      fw.version.description, up.elapsed))
            } catch {
                result = .failed("\(error)\n\nThe charger stays in update mode: you can simply install again.")
            }
            DispatchQueue.main.async {
                ProcessInfo.processInfo.endActivity(activity)
                self.phase = result
                if case let .done(m) = result { self.note(m) }
                if case let .failed(m) = result { self.note(m) }
                self.lastSeen = false // re-identify once the charger reappears
            }
        }
    }

    private func show(_ p: FirmwareUpdater.Phase) {
        switch p {
        case .identifying: progressText = "Checking the charger…"
        case .erasing: progressText = "Erasing…"; progress = 0.02
        case let .writing(done, total):
            progress = 0.02 + 0.95 * Double(done) / Double(max(total, 1))
            progressText = "Writing \(done * 100 / max(total, 1)) %"
        case .checking: progressText = "The charger is checking the new firmware…"; progress = 0.98
        case .starting: progressText = "Starting the new firmware…"; progress = 0.99
        case .finished: progressText = "Done"; progress = 1
        }
    }
}

// MARK: Views

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChargerBox()
            FirmwareBox()
            InstallBox()
            LogBox()
        }
        .padding(18)
    }
}

struct ChargerBox: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox(label: Label("Charger", systemImage: "bolt.batteryblock")) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let c = model.charger {
                        Text(c.model ?? "Cayote charger").font(.headline)
                        if c.inUpdateMode {
                            Text("In update mode – waiting for firmware").foregroundColor(.orange)
                            Text("Bootloader \(c.firmware?.description ?? "?")  ·  hardware \(c.hardware?.description ?? "?")  ·  "
                                + "the installed firmware version is shown in About Device on the charger")
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Firmware \(c.firmware?.description ?? "?")  ·  hardware \(c.hardwareDescription ?? "?")")
                        }
                        if let cmp = model.comparison {
                            if model.upToDate {
                                Label(cmp, systemImage: "checkmark.circle.fill").foregroundColor(.green)
                            } else {
                                Text(cmp).foregroundColor(.secondary)
                            }
                        }
                    } else if model.deviceConnected {
                        Text(model.chargerError ?? "Connected – asking who it is…").foregroundColor(.secondary)
                    } else {
                        Text("No charger connected").font(.headline)
                        Text("Use the USB-C Upgrade Port on the back of the charger (between the DC and AC inputs) "
                            + "and the upgrade cable from the box. The front USB-C port only supplies power.")
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Refresh") { model.identify() }
                    .disabled(!model.deviceConnected || model.phase.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

struct FirmwareBox: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox(label: Label("Firmware", systemImage: "shippingbox")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.onlineStatus).foregroundColor(.secondary)
                    Spacer()
                    Button("Check for Updates") { model.checkForUpdates() }
                    Button(model.downloading ? "Downloading…" : (model.latestIsOpen ? "Downloaded" : "Download")) {
                        model.downloadLatest()
                    }
                    .disabled(model.latest == nil || model.downloading || model.latestIsOpen || model.phase.isBusy)
                }
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let fw = model.firmware {
                            Text("\(fw.model) firmware \(fw.version.description)").font(.headline)
                            Text(model.firmwareSource?.lastPathComponent ?? "").foregroundColor(.secondary)
                            Text("Checksums and file layout verified.").foregroundColor(.secondary).font(.caption)
                        } else {
                            Text("No firmware chosen").font(.headline)
                            Text(model.firmwareError ?? "Download it above, or open Cayote's .7z, the updater .exe or a .grp.")
                                .foregroundColor(model.firmwareError == nil ? .secondary : .red)
                        }
                    }
                    Spacer()
                    Button("Open File…") { model.chooseFirmware() }.disabled(model.phase.isBusy)
                }
            }
            .padding(6)
        }
    }
}

struct InstallBox: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox(label: Label("Install", systemImage: "arrow.down.circle")) {
            VStack(alignment: .leading, spacing: 10) {
                if model.upToDate && model.phase == .idle {
                    Text("Nothing to install – the charger already has the newest firmware. You can still "
                        + "reinstall it with the steps below; that is harmless.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Use a USB-A to USB-C data cable in the charger's rear Upgrade Port, through a powered "
                    + "hub or dock (a Mac's own port may cut the power). Keep the charger's AC power disconnected.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Unplug the cable's USB-A end (leave the other end in the charger).\n"
                    + "2. Hold UP on the charger and plug the USB-A end back in.\n"
                    + "3. Release UP when the charger beeps three times.\n"
                    + "4. Click Check Charger (this changes nothing), then Install. The charger's screen stays "
                    + "dark until it finishes.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Check Charger") { model.checkCharger() }
                        .disabled(model.firmware == nil || !model.deviceConnected || model.phase.isBusy)
                    Button("Install…") { model.install() }
                        .disabled({ if case .ready = model.phase { return false }; return true }())
                        .keyboardShortcut(.defaultAction)
                    Spacer()
                }
                switch model.phase {
                case .idle: EmptyView()
                case .checking: Text("Checking…").foregroundColor(.secondary)
                case let .ready(m): Label(m, systemImage: "checkmark.circle").foregroundColor(.green)
                case .installing:
                    ProgressView(value: model.progress) { Text(model.progressText) }
                    Text("Don't unplug the charger or let the Mac sleep.").foregroundColor(.orange)
                case let .done(m): Label(m, systemImage: "checkmark.seal").foregroundColor(.green)
                case let .failed(m): Label(m, systemImage: "exclamationmark.triangle").foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

struct LogBox: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox(label: Label("Log", systemImage: "list.bullet.rectangle")) {
            ScrollView {
                Text(model.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 80)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.current?.phase == .installing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Firmware is being written"
        alert.informativeText = "Quitting now would leave the charger without firmware until the update is run again."
        alert.addButton(withTitle: "Keep Running")
        alert.runModal()
        return .terminateCancel
    }
}

struct CayoteLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("CayoteLink", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 620)
                .onOpenURL { url in if url.isFileURL { model.openFirmware(url) } }
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

CayoteLinkApp.main()
