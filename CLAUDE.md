# CLAUDE.md – working on CayoteLink

Guidance for AI agents (and humans) extending this repository. Read `docs/PROTOCOL.md` before
changing anything that talks to a charger. Sister project: [NobleLink](https://github.com/trelaf/NobleLink)
(same structure; its `tools/ghidra_scripts` were used for the reverse engineering here).

## Layout

```
CayoteLink/                     Swift package (macOS 13+, no third-party dependencies)
  Sources/CayoteKit/
    Frame.swift                 A5×5 framing, 0xCC stuffing, sum16, 64-byte report split, parser
    FirmwareFile.swift          .grp header, sum32, identity block, Version, CayoteError
    Charger.swift               transport protocol, ChargerLink (request/reply + commands), ChargerInfo
    HIDTransport.swift          IOKit HID (VID 0x28E9 PID 0x0189, usage 0x8C/6, 64-byte reports)
    FirmwareUpdater.swift       preflight (read-only) + install (erase / write / check / run)
    MockCharger.swift           simulated charger: normal firmware + bootloader with NOR flash
    UpdaterPackage.swift        .7z/.exe/.grp loading; cayote.com update check + download
  Sources/cayote/               command-line tool
  Sources/CayoteLinkApp/        SwiftUI app (single file; AppModel holds all state)
  Sources/CayoteSelfTest/       test runner (plain executable, see below)
  Resources/AppIcon.icns
  scripts/build_app.sh          universal release build + .app bundle (version lives here)
  scripts/package_release.sh    zips + SHA256SUMS for a GitHub release
docs/PROTOCOL.md                protocol, file format, update sequence – with sources
icon/                           icon master + .icns
```

## Build and test

```sh
cd CayoteLink
swift build
.build/debug/CayoteSelfTest ../samples     # ~55 checks with no samples, ~65 with Cayote's .7z
./scripts/build_app.sh                     # dist/CayoteLink.app, dist/cayote
.build/debug/cayote simulate FILE          # full install against the simulator
```

- Releases: bump `VERSION` in `scripts/build_app.sh`, run `./scripts/package_release.sh`, publish
  `dist/release/*` with `gh release create vX.Y.Z`. Binaries go in releases, never in the repository.
- The toolchain may be the Command Line Tools only: **no XCTest / swift-testing** (hence
  `CayoteSelfTest` is an executable) and **no SwiftUI `@State`** – keep view state in `AppModel`.
- `samples/firmware/` (git-ignored) holds Cayote's `.7z`, downloadable from cayote.com. Tests that
  need it are skipped when absent. Never commit Cayote's files or decompiled code.
- Everything is testable without hardware: `MockCharger` models the charger, including what was
  observed on the real one. Extend it when you learn something new, and add a check.

## Rules that keep a charger safe

1. Nothing is written before `FirmwareUpdater.preflight()` passes: the charger must be in update
   mode (Identify `payload[3] != 0`), and the official identity check must pass.
2. Validate every file with `FirmwareFile.problems` (both checksums, load address 0x08004000,
   length, vector table). Never write below 0x08004000 (the bootloader).
3. Ask the user before `install`. `info` and `probe` must stay read-only (Identify only).
4. 0x22 (restart into update mode) is untested: CLI only, behind `--experimental`.
5. Anything new about the hardware goes into `docs/PROTOCOL.md` with how it is known
   ([host] Cayote's updater, [fw] charger firmware, [file] firmware file, [hw] seen on a charger).

## What is verified on real hardware (2026-11-16)

2-Force X5, hardware 1.0.1, bootloader 1.0.0: Identify in normal and update mode, probe, and
installing V1.2.9 with the CLI (19 s). The connection was a USB-A to USB-C data cable through a
powered dock, with no AC power. Not yet: the app's Install button (same code path), and 0x22.

## Ideas

- Try 0x22 so updates no longer need the UP key.
- Decode the charger's status/control commands (0x51, 0x59–0x6B) for a live charging view.
