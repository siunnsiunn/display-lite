import Foundation
import IOKit
import Darwin

/// Runtime lookup avoids a launch-time failure if a future macOS removes private symbols.
private final class AVAPI {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    let handle: UnsafeMutableRawPointer
    let create: Create
    let read: Transfer
    let write: Transfer

    init() throws {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL) else {
            throw DDCError.invalid("cannot load IOKit")
        }
        guard let c = dlsym(handle, "IOAVServiceCreateWithService"),
              let r = dlsym(handle, "IOAVServiceReadI2C"),
              let w = dlsym(handle, "IOAVServiceWriteI2C") else {
            dlclose(handle)
            throw DDCError.invalid("private IOAVService API unavailable")
        }
        self.handle = handle
        create = unsafeBitCast(c, to: Create.self)
        read = unsafeBitCast(r, to: Transfer.self)
        write = unsafeBitCast(w, to: Transfer.self)
    }
    deinit { dlclose(handle) }
}

public struct DisplayInfo: Sendable {
    public let name: String
    public let registryID: UInt64
    public let registryPath: String
    public let edidUUID: String?
    public let manufacturer: String?
    public let serial: String?
    public let available: Bool
}

public struct ReadOptions: Sendable {
    public var tries: Int
    public var interval: TimeInterval
    public var checksumMode: GetChecksumMode
    public init(tries: Int = 5, interval: TimeInterval = 0.05, checksumMode: GetChecksumMode = .appleSilicon) {
        self.tries = tries; self.interval = interval; self.checksumMode = checksumMode
    }
    fileprivate func validate() throws {
        guard (1...1000).contains(tries), interval.isFinite, interval >= 0, interval <= 60 else {
            throw DDCError.invalid("tries must be 1...1000; interval must be 0...60 seconds")
        }
    }
}

/// Synchronous connection, deliberately not Sendable. Serialize access to a monitor
/// (including other processes); a request and its reply must not interleave.
public final class DDCDisplay {
    public let info: DisplayInfo
    private let api: AVAPI
    private let service: CFTypeRef?
    private init(info: DisplayInfo, api: AVAPI, service: CFTypeRef?) {
        self.info = info; self.api = api; self.service = service
    }

    /// Enumerates external DCPAVServiceProxy endpoints; not a guessed CGDisplayID mapping.
    public static func list() throws -> [DDCDisplay] {
        #if !arch(arm64)
        throw DDCError.invalid("IOAVService backend requires Apple Silicon")
        #else
        let api = try AVAPI()
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
        guard result == KERN_SUCCESS else { throw DDCError.invalid("IORegistry enumeration failed: \(result)") }
        defer { IOObjectRelease(iterator) }
        var displays: [DDCDisplay] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            func property(_ key: String, ancestors: Bool = false) -> Any? {
                if ancestors {
                    return IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString,
                        kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
                }
                return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard property("Location") as? String == "External" else { continue }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS else { continue }
            var path = [CChar](repeating: 0, count: 4096)
            let pathStatus = IORegistryEntryGetPath(entry, kIOServicePlane, &path)
            let registryPath = pathStatus == KERN_SUCCESS ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "unavailable"
            let attributes = property("DisplayAttributes", ancestors: true) as? [String: Any]
            let product = attributes?["ProductAttributes"] as? [String: Any]
            let name = product?["ProductName"] as? String ?? "Unknown external display"
            let serial = product?["AlphanumericSerialNumber"] as? String
                ?? (product?["SerialNumber"] as? NSNumber)?.stringValue
            let service = api.create(kCFAllocatorDefault, entry)?.takeRetainedValue()
            let info = DisplayInfo(name: name, registryID: registryID, registryPath: registryPath,
                edidUUID: property("EDID UUID", ancestors: true) as? String,
                manufacturer: product?["ManufacturerID"] as? String, serial: serial,
                available: service != nil)
            displays.append(DDCDisplay(info: info, api: api, service: service))
        }
        return displays.sorted { $0.info.registryID < $1.info.registryID }
        #endif
    }

    private func send(_ packet: [UInt8]) throws -> IOReturn {
        guard let service else { throw DDCError.invalid("IOAVService could not open this endpoint") }
        var bytes = packet
        return bytes.withUnsafeMutableBytes {
            api.write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
        }
    }

    private func receive(count: Int) throws -> (IOReturn, [UInt8]) {
        guard let service else { throw DDCError.invalid("IOAVService could not open this endpoint") }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes {
            api.read(service, 0x37, 0, $0.baseAddress!, UInt32($0.count))
        }
        return (status, bytes)
    }

    /// Runs ALL attempts, even after a valid sample, to expose unstable reads.
    public func readReport(vcp: UInt8, options: ReadOptions = ReadOptions(),
                           onAttempt: ((ReadAttempt) -> Void)? = nil) throws -> ReadReport {
        try options.validate()
        var attempts: [ReadAttempt] = []
        for index in 0..<options.tries {
            if index > 0 { Thread.sleep(forTimeInterval: options.interval) }
            let writeStatus = try send(DDCPacket.get(vcp, mode: options.checksumMode))
            var raw: [UInt8] = []
            var readStatus: IOReturn?
            if writeStatus == 0 {
                Thread.sleep(forTimeInterval: options.interval)
                let response = try receive(count: 11)
                readStatus = response.0; raw = response.1
            }
            let attempt = ReadAttempt(number: index + 1, raw: raw, writeStatus: writeStatus, readStatus: readStatus, vcp: vcp)
            attempts.append(attempt); onAttempt?(attempt)
        }
        return ReadReport(attempts: attempts)
    }

    public func read(vcp: UInt8, options: ReadOptions = ReadOptions()) throws -> (current: UInt16, max: UInt16) {
        let report = try readReport(vcp: vcp, options: options)
        guard let value = report.accepted else { throw DDCError.invalid("no trustworthy VCP result; use readReport for raw attempts") }
        return (value.current, value.max)
    }

    /// Success means the I2C calls succeeded, not that the monitor applied the value.
    public func write(vcp: UInt8, value: UInt16, repetitions: Int = 2, interval: TimeInterval = 0.05) throws {
        try ReadOptions(tries: repetitions, interval: interval).validate()
        var failures: [IOReturn] = []
        for index in 0..<repetitions {
            if index > 0 { Thread.sleep(forTimeInterval: interval) }
            let status = try send(DDCPacket.set(vcp, value: value))
            if status != 0 { failures.append(status) }
        }
        if !failures.isEmpty { throw DDCError.invalid("Set VCP I2C failures: \(failures); value may have been partially applied") }
    }

    public func capabilities(options: ReadOptions = ReadOptions()) throws -> String {
        try options.validate()
        var chunks: [CapabilityChunk] = []
        var progress = try CapabilityProgress.assemble(chunks)
        // Bounded even for a monitor that never sends a terminator.
        for _ in 0..<4096 {
            let offset = progress.nextOffset
            var accepted: CapabilityChunk?
            var lastError = "no reply"
            for _ in 0..<options.tries {
                Thread.sleep(forTimeInterval: options.interval)
                let status = try send(DDCPacket.capabilities(offset: offset))
                if status != 0 { lastError = "write I2C status \(status)"; continue }
                Thread.sleep(forTimeInterval: options.interval)
                let (readStatus, raw) = try receive(count: 38)
                if readStatus != 0 { lastError = "read I2C status \(readStatus)"; continue }
                do {
                    let chunk = try DDCPacket.parseCapabilities(raw, expectedOffset: offset)
                    _ = try CapabilityProgress.assemble(chunks + [chunk])
                    accepted = chunk; break
                } catch { lastError = String(describing: error) }
            }
            guard let accepted else { throw DDCError.invalid("capabilities offset \(offset): \(lastError)") }
            chunks.append(accepted)
            progress = try CapabilityProgress.assemble(chunks)
            if progress.complete { return String(decoding: progress.bytes, as: UTF8.self) }
        }
        throw DDCError.invalid("capabilities fragment limit exceeded")
    }
}
