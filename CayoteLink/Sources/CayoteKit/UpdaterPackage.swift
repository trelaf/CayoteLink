import Foundation

/// Getting a `.grp` out of what Cayote publishes: the `.7z` download, the Windows
/// updater `.exe` inside it (the file is a Qt resource stored uncompressed), or a bare `.grp`.
public enum UpdaterPackage {
    /// Every valid firmware file embedded in `data` (an updater .exe, or a .grp itself).
    public static func firmwareFiles(in data: Data) -> [FirmwareFile] {
        let bytes = [UInt8](data)
        var found: [FirmwareFile] = []
        var seen = Set<Int>()
        let magic: [UInt8] = [0x78, 0x56, 0x34, 0x12]
        var i = 0x10
        while i + 4 <= bytes.count {
            if bytes[i] == magic[0], bytes[i + 1] == magic[1], bytes[i + 2] == magic[2], bytes[i + 3] == magic[3] {
                let s = i - 0x10
                if s + FirmwareFile.headerSize <= bytes.count,
                   Checksum.sum32(bytes[s..<(s + 0x58)]) == readLE32(bytes, s + 0x58) {
                    let len = Int(readLE32(bytes, s + 0x08))
                    let end = s + FirmwareFile.headerSize + len
                    if len > 0, end <= bytes.count, !seen.contains(s),
                       let fw = try? FirmwareFile(data: Data(bytes[s..<end])) {
                        found.append(fw)
                        seen.insert(s)
                        i = end
                        continue
                    }
                }
            }
            i += 1
        }
        return found
    }

    /// Load firmware from a `.grp`, an updater `.exe`, or a `.7z`/`.zip` containing one.
    public static func load(_ url: URL) throws -> FirmwareFile {
        let ext = url.pathExtension.lowercased()
        if ["7z", "zip"].contains(ext) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CayoteLink-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try extract(archive: url, into: dir)
            var all: [FirmwareFile] = []
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
            while let f = files?.nextObject() as? URL {
                guard ["exe", "grp"].contains(f.pathExtension.lowercased()) else { continue }
                all += firmwareFiles(in: try Data(contentsOf: f))
            }
            return try pick(all, source: url)
        }
        let data = try Data(contentsOf: url)
        if ext == "grp" { return try FirmwareFile(data: data) }
        return try pick(firmwareFiles(in: data), source: url)
    }

    private static func pick(_ files: [FirmwareFile], source: URL) throws -> FirmwareFile {
        guard let first = files.first else {
            throw CayoteError.badFirmware("no Cayote firmware found in \(source.lastPathComponent)")
        }
        guard files.allSatisfy({ $0.data == first.data }) else {
            throw CayoteError.badFirmware("\(source.lastPathComponent) contains \(files.count) different firmware files")
        }
        return first
    }

    /// Unpack with macOS's own bsdtar, which reads 7z and zip.
    static func extract(archive: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xf", archive.path, "-C", dir.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CayoteError.badFirmware("could not unpack \(archive.lastPathComponent): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

/// Cayote's product page lists the current updater download.
public enum UpdateCheck {
    public static let productPage = URL(string: "https://cayote.com/product/2-force-x5/")!

    public struct Release: Equatable, Sendable {
        public var version: Version
        public var build: Int?
        public var url: URL
        public var label: String { "V\(version)" + (build.map { "-\($0)" } ?? "") }
    }

    /// Find `Cayote-2-Force-X5-V<version>[-<build>].7z` links in the page's HTML; newest first.
    public static func releases(inHTML html: String, base: URL = productPage) -> [Release] {
        let pattern = #"(?:href|src)\s*=\s*["']([^"']*?Cayote-2-Force-X5-V(\d+\.\d+\.\d+)(?:-(\d+))?\.(?:7z|zip))["']"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var out: [Release] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let link = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: link, relativeTo: base)?.absoluteURL,
                  url.scheme == "https",
                  let v = Version(ns.substring(with: m.range(at: 2))) else { continue }
            let build = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) : nil
            let r = Release(version: v, build: build, url: url)
            if !out.contains(r) { out.append(r) }
        }
        return out.sorted { ($0.version, $0.build ?? 0) > ($1.version, $1.build ?? 0) }
    }

    public static func latest() async throws -> Release {
        var req = URLRequest(url: productPage)
        req.setValue("CayoteLink", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CayoteError.failed("Cayote's website answered with an error.")
        }
        guard let r = releases(inHTML: String(decoding: data, as: UTF8.self)).first else {
            throw CayoteError.failed("No firmware download was found on Cayote's product page.")
        }
        return r
    }

    /// Download into `directory` (kept if it already exists and is valid).
    public static func download(_ release: Release, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(release.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path), (try? UpdaterPackage.load(dest)) != nil { return dest }
        let (tmp, resp) = try await URLSession.shared.download(from: release.url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CayoteError.failed("The download failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    public static var downloadsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CayoteLink/Downloads")
    }
}
