# Cayote 2-Force X5 – USB protocol and firmware update

Reverse-engineered from Cayote's Windows updater *Cayote 2-Force X5 V1.2.9.exe* (from
`Cayote-2-Force-X5-V1.2.9-4.7z`) and from the charger firmware embedded in it.
Sources are tagged: **[host]** the updater, **[fw]** the charger's main firmware,
**[file]** the firmware file, **[hw]** seen on a real charger.

The charger is built by Grepow; internally it is the **"Cayote D700"**. The chip is a GigaDevice
GD32 (Cortex-M, STM32F1-compatible): the USB vendor ID is GigaDevice's, and the unique-ID register
read by the firmware is at 0x1FFFF7E8 [fw].

## 1. USB

| | |
|---|---|
| VID / PID | **0x28E9 / 0x0189**, in both normal and update mode [host: FUN_004085d0 calls the opener with 0x28E9, 0x189] [fw: device descriptor at 0x0806C550] |
| Interface | HID, usage page **0x008C**, usage **0x0006** [host checks HidP_GetCaps] [fw: report descriptor at 0x0806C590] |
| Reports | 64-byte input and 64-byte output, **no report IDs**; interrupt endpoints 0x81 / 0x01, 20 ms [fw] |
| Strings | manufacturer "The GREPOWBattery CO.,LTD" [fw] |

The host writes a frame (§2) as a byte stream cut into 64-byte output reports. The last report is
zero-padded, and every write must be accepted as 64 bytes [host FUN_00407700]. Replies arrive the
same way. The receiver feeds every received byte to the frame parser (§2), which skips anything
outside a frame, including the padding.

## 2. Frames

```
A5 A5 A5 A5 A5 | dst | src | len | payload[len] | sumLo | sumHi
```

- **Preamble:** five 0xA5 bytes.
- **Addresses:** host → charger frames use `dst 0x11, src 0x20`. Charger → host frames use
  `dst 0x20, src 0x11`; the charger copies the request's first byte into the second byte of its
  reply [fw FUN_08034944]. The updater only accepts a reply whose second byte is 0x11 [host
  FUN_00407500, expected value set by FUN_00407160(…, 0x11)]. It does not check the first byte.
- **len:** payload length, 0–255.
- **sum:** 16-bit sum of the bytes `dst + src + len + payload`, sent low byte first.
- **Byte stuffing:** after the preamble, whenever four consecutive 0xA5 bytes have been sent, the
  sender inserts a 0xCC. The receiver counts consecutive 0xA5 bytes and discards the byte that
  follows four of them [host FUN_00407380 / FUN_00407500] [fw FUN_0803950C]. The final checksum
  byte is never followed by a stuffing byte.
- `payload[0]` is the **command**. A reply echoes the command in `payload[0]`. In the main firmware,
  an unknown command or a failure is answered with `command | 0x80` (e.g. 0xE3) [fw].

## 3. Commands used for a firmware update [host]

The updater runs these steps in this order and stops at the first failure [host FUN_004085d0]:

| # | Step | Request payload | Expected reply | Timeout |
|---|---|---|---|---|
| 1 | Open the device | – | – | – |
| 2 | **0x20 Identify** | `20` | `payload[0]==0x20` and `payload[3]!=0` (update mode) | 1 s, 3 tries |
| 3 | Load and validate the `.grp` (§5) | | | |
| 4 | **0x20 Identify**, check identity | `20` | identity matches the file (below) | 1 s |
| 5 | **0x30 Erase** | `30 00 00 00` `u32 address` `u32 length` (12 bytes) | `30` | 30 × 0.5 s |
| 6 | **0x32 Write**, repeated | `32 00 00 00` `u32 address` `u32 n` `data[224]` (always 236 bytes; `n` ≤ 224 is the number of valid bytes) | `32` | 10 s for the first, then 5 s |
| 7 | **0x33 Check** | `33 00 00 00` `u32 address` `u32 length` | `33` | 0.5 s |
| 8 | **0x21 Run** | `21` | `21` | 0.5 s, 3 tries |

- All integers are little-endian. *address* is the file's load address (0x08004000) and *length*
  is the image length. For writes, *address* is load + offset and the data is the next ≤ 224 bytes.
  In the last write the official tool leaves stale bytes after `n`; we send 0xFF there.
- The three padding bytes after the command are not initialised by the official tool, so their
  value doesn't matter; we send zeros.
- 0x33 carries no checksum. The charger checks the image itself and answers `0x33` on success
  (presumably 0xB3 on failure, following the firmware's error convention). There is no read-back
  command.
- The updater has no command to enter update mode. The manual (p. 24) says: use the supplied USB
  upgrade cable (USB-C to USB-A) in the **rear "USB-C Upgrade Port"** (p. 8, item 13, between the
  EC5 DC input and the AC input). Plug the USB-C end into the charger, hold **UP**, plug the USB-A
  end into the computer, and release UP after **three beeps**. The screen stays dark during the
  update. The front USB-C port is a 5 V/2 A power output with no data.

### Identity check (step 4) [host FUN_00407BB0, FUN_00407B10]

The reply payload holds an *identity block* (§4) at offset 0x14. Identify succeeds only if all
of these hold:

- the block's hardware major, hardware minor and software major (block bytes 0x40, 0x41 and 0x42)
  equal the file's (header bytes 0x50–0x52);
- `strncmp(block+0x04, header+0x14, 40) == 0`, the vendor ("The GREPOW CO.,LTD");
- `strncmp(block+0x2C, header+0x3C, 20) == 0`, the model ("Cayote D700"). Files for the model
  "G6 Devices" also accept chargers named "G6" or "G6 Pro".

## 4. Identify reply (0x20) and identity block

The main firmware's reply (`len` 0x5C) [fw FUN_08034944]:

| Payload offset | Content |
|---|---|
| 0x00 | 0x20 |
| 0x01 | 0x06 (constant; meaning unknown) |
| 0x02 | 0x02 (constant; meaning unknown) |
| 0x03 | **mode: 0 = normal firmware**. The updater requires a non-zero value here, i.e. the bootloader. |
| 0x04–0x07 | the bootloader identity's software version: u16 patch, minor, major |
| 0x0C–0x17 | the chip's 96-bit unique ID (from 0x1FFFF7E8) |
| 0x14–0x5B | identity block (0x48 bytes). Its first 4 bytes (the magic) are overwritten by the end of the unique ID. |

**Identity block.** It is the same 0x48 bytes as `.grp` header 0x10–0x57, and the firmware also
carries a copy at 0x0806CD34:

| Block offset | Size | Content | V1.2.9 |
|---|---|---|---|
| 0x00 | 4 | magic 0x12345678 | |
| 0x04 | 40 | vendor, NUL-padded | "The GREPOW CO.,LTD" |
| 0x2C | 20 | model, NUL-padded | "Cayote D700" |
| 0x40 | 1 | hardware major | 1 |
| 0x41 | 1 | hardware minor | 0 |
| 0x42 | 1 | software major | 1 |
| 0x43 | 1 | software minor | 2 |
| 0x44 | 2 | hardware patch | 0 |
| 0x46 | 2 | software patch | 9 |

The charger's About screen prints `HARDWARE: a.b.c` from the bootloader's identity block and
`SOFTWARE: 1.2.9`, which is compiled into the firmware [fw FUN_08017052, FUN_08029304]. The firmware
finds the bootloader's block through the word at 0x08000034, which is the reserved slot 13 of the
bootloader's vector table; the application's own slot 13 (0x08004034) points to its block, so the
bootloader can presumably find it the same way.

So in **normal mode**, Identify is a harmless, read-only way to learn the model and installed
firmware version. In **update mode** the bootloader answers instead. Its reply is assumed to have
the same layout, because the updater reads it that way, but it has not been seen yet.

### Other commands in the main firmware [fw, not used by the updater]

- 0x21: reply `21 01`; also stops something (output/charging?).
- **0x22: reboot into update mode.** The firmware replies, writes 0x1234 into six backup
  registers, then resets the chip (SYSRESETREQ). It is presumably the software alternative to
  holding UP. The official updater never sends it.
- 0x51, 0x59–0x6B: charger status and control (channels A/B). Not analysed.

## 5. Firmware file (`.grp`)

The updater carries the file as the Qt resource `:/Cayote D700.grp`. The resource data is stored
uncompressed, preceded by a big-endian u32 size.

| Offset | Size | Content (V1.2.9) |
|---|---|---|
| 0x00 | 4 | 0 |
| 0x04 | 4 | load address 0x08004000 (the updater refuses anything else) |
| 0x08 | 4 | image length 0x6CA30 (non-zero, multiple of 16, equal to file size − 0x5C) |
| 0x0C | 4 | sum32 of the image (0x803B4C46) |
| 0x10 | 0x48 | identity block (§4) |
| 0x58 | 4 | sum32 of header bytes 0x00–0x57 (0x5042286A) |
| 0x5C | | image: a raw Cortex-M application (vector table first; SP 0x2000BC18, reset 0x0806D1DD) |

**sum32:** the sum, mod 2³², of the data read as little-endian u32 words; any 1–3 byte tail is read
as a zero-padded little-endian word [host FUN_004072A0].

The bootloader occupies 0x08000000–0x08003FFF. It is not in the file and is never written.

## 6. Where updates come from

Cayote's product page `https://cayote.com/product/2-force-x5/` links the current updater as
`…/wp-content/uploads/YYYY/MM/Cayote-2-Force-X5-V<version>-<n>.7z` (V1.2.9-4 on 2026-11-14).

## 7. Seen on hardware (2026-11-16)

The charger was in update mode, powered from USB only through a powered dock's USB-A port (no AC).

- Enumerates as `28E9:0189` "Grepow Smart Charger" by "Shenzhen GREPOW CO.,LTD", usage 0x8C/6,
  64/64-byte reports, as predicted.
- With a USB-C to USB-C cable the Mac sees nothing; a USB-A to USB-C cable is needed. A direct
  Mac port tripped its overcurrent protection; the dock worked.
- The bootloader's Identify reply (92 bytes):

```
00  20 06 02 01 01 02 01 00 50 00 00 20 xx xx xx xx     mode = 01 (update)
10  xx xx xx xx xx xx xx xx 54 68 65 20 47 52 45 50     chip ID 0x0C–0x17 (redacted)
20  4F 57 20 43 4F 2E 2C 4C 54 44 00 00 00 00 00 00     vendor
30  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
40  43 61 79 6F 74 65 20 44 37 30 30 00 00 00 00 00     model "Cayote D700"
50  00 00 00 00 01 00 01 00 01 00 00 00                 hw 1.0, sw 1.0, hw patch 1, sw patch 0
```

  It carries the **bootloader's own identity**: hardware 1.0.1, bootloader 1.0.0. That passes the
  updater's check (bytes 01 00 01) without saying which application firmware is installed.
  Bytes 0x04–0x07 (`01 02 01 00`) and 0x08–0x0B (`50 00 00 20`, then `04 00 00 00` on the next
  request) are not understood yet.
- `cayote probe` with V1.2.9 passed.
- **`cayote install` V1.2.9 succeeded: erase, 1987 writes, check and run in 19 s.** The charger
  restarted into the normal firmware by itself, still powered over USB.
- The normal firmware enumerates as `28E9:0189` **"G6 Smart Charger"** by "The GREPOWBattery
  CO.,LTD" (the bootloader calls itself "Grepow Smart Charger"). Its Identify reply matches §4
  exactly: mode 00, bytes 0x04–0x07 `00 00 00 01` = bootloader 1.0.0, and the application's
  identity block, software **1.2.9**. The hardware fields in that block say 1.0.0 (whatever
  the build targets); the real board revision (1.0.1) is only in the bootloader's block.

```
00  20 06 02 00 00 00 00 01 00 00 00 00 xx xx xx xx
10  xx xx xx xx xx xx xx xx 54 68 65 20 47 52 45 50
20  4F 57 20 43 4F 2E 2C 4C 54 44 00 00 00 00 00 00
30  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
40  43 61 79 6F 74 65 20 44 37 30 30 00 00 00 00 00
50  00 00 00 00 01 00 01 02 00 00 09 00
```

## 8. Not yet known

- What 0x33 checks, and what a failed check returns.
- Whether 0x22 reliably enters update mode (normal mode works over the dock, so it can be tried).
