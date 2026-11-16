import Foundation
import IOKit
import IOKit.hid

/// One HID interface of a connected charger.
public struct HIDDeviceDescription: Sendable, CustomStringConvertible {
    public var vendorID: UInt16
    public var productID: UInt16
    public var product: String
    public var manufacturer: String
    public var usagePage: Int
    public var usage: Int
    public var maxInputReport: Int
    public var maxOutputReport: Int
    public var locationID: Int

    public var description: String {
        String(format: "[%04X:%04X] \"%@\" by \"%@\" usage %04X:%04X in=%d out=%d loc=%08X",
               vendorID, productID, product, manufacturer, usagePage, usage, maxInputReport, maxOutputReport, locationID)
    }
}

/// USB HID transport on IOKit. The charger uses un-numbered 64-byte reports both ways.
public final class HIDTransport: ChargerTransport {
    /// GigaDevice's vendor ID; the charger keeps it in normal and update mode.
    public static let vendorID = 0x28E9
    public static let productID = 0x0189
    public static let usagePage = 0x008C
    public static let usage = 0x0006
    public static let reportSize = 64

    public let description: HIDDeviceDescription
    private let device: IOHIDDevice
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferSize = 256
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var removed = false
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var isOpen = false

    private static func describe(_ d: IOHIDDevice) -> HIDDeviceDescription {
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0 }
        func str(_ key: String) -> String {
            let raw = IOHIDDeviceGetProperty(d, key as CFString) as? String ?? ""
            return String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }))
                .trimmingCharacters(in: .whitespaces)
        }
        return HIDDeviceDescription(
            vendorID: UInt16(truncatingIfNeeded: int(kIOHIDVendorIDKey)),
            productID: UInt16(truncatingIfNeeded: int(kIOHIDProductIDKey)),
            product: str(kIOHIDProductKey), manufacturer: str(kIOHIDManufacturerKey),
            usagePage: int(kIOHIDPrimaryUsagePageKey), usage: int(kIOHIDPrimaryUsageKey),
            maxInputReport: int(kIOHIDMaxInputReportSizeKey), maxOutputReport: int(kIOHIDMaxOutputReportSizeKey),
            locationID: int(kIOHIDLocationIDKey))
    }

    /// Same match as the official updater: VID/PID plus usage page 0x8C, usage 6.
    private static func candidates() -> [(IOHIDDevice, HIDDeviceDescription)] {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return [] }
        return set.map { ($0, describe($0)) }
            .filter { $0.1.usagePage == usagePage && $0.1.usage == usage }
            .sorted { $0.1.locationID < $1.1.locationID }
    }

    public static func connectedDevices() -> [HIDDeviceDescription] { candidates().map(\.1) }

    public static func openFirst() throws -> HIDTransport {
        let all = candidates()
        guard let (device, desc) = all.first else { throw CayoteError.noDevice }
        guard all.count == 1 else {
            throw CayoteError.openFailed("\(all.count) chargers are connected; connect only the one to update")
        }
        let t = HIDTransport(device: device, description: desc)
        try t.open()
        return t
    }

    private init(device: IOHIDDevice, description: HIDDeviceDescription) {
        self.device = device
        self.description = description
        inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
        inputBuffer.initialize(repeating: 0, count: inputBufferSize)
    }

    deinit {
        close()
        inputBuffer.deallocate()
    }

    private func open() throws {
        let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else {
            throw CayoteError.openFailed(String(format: "IOHIDDeviceOpen returned 0x%08X", rc))
        }
        isOpen = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputBufferSize, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().enqueue(Data(bytes: report, count: length))
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { ctx, _, _ in
            guard let ctx else { return }
            Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().markRemoved()
        }, context)

        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { return }
            guard let rl = CFRunLoopGetCurrent() else { ready.signal(); return }
            self.runLoop = rl
            IOHIDDeviceScheduleWithRunLoop(self.device, rl, CFRunLoopMode.defaultMode.rawValue)
            ready.signal()
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            IOHIDDeviceUnscheduleFromRunLoop(self.device, rl, CFRunLoopMode.defaultMode.rawValue)
        }
        t.name = "CayoteKit.HID"
        t.start()
        thread = t
        ready.wait()
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        thread?.cancel()
        if let rl = runLoop { CFRunLoopStop(rl) }
        Thread.sleep(forTimeInterval: 0.3)
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputBufferSize, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func enqueue(_ data: Data) {
        condition.lock()
        queue.append(data)
        condition.signal()
        condition.unlock()
    }

    private func markRemoved() {
        condition.lock()
        removed = true
        condition.broadcast()
        condition.unlock()
    }

    public func write(report: Data) throws {
        guard isOpen, !removed else { throw CayoteError.ioFailed("the charger was disconnected") }
        precondition(report.count == Self.reportSize)
        let rc = report.withUnsafeBytes { raw -> IOReturn in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, raw.bindMemory(to: UInt8.self).baseAddress!, report.count)
        }
        guard rc == kIOReturnSuccess else {
            throw CayoteError.ioFailed(String(format: "sending a report failed (0x%08X)", rc))
        }
    }

    public func read(timeout: TimeInterval) throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty {
            if removed { throw CayoteError.ioFailed("the charger was disconnected") }
            if !condition.wait(until: deadline) { return nil }
        }
        return queue.removeFirst()
    }
}
