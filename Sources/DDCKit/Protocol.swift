/// Pure packet and selection logic; no hardware or timing dependencies.
public enum DDCError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let message): return message }
    }
}

public struct VCPValue: Equatable, Hashable, Sendable {
    public let current: UInt16
    public let max: UInt16
    /// 0 = continuous, 1 = non-continuous. Keep this when comparing samples.
    public let type: UInt8
    public init(current: UInt16, max: UInt16, type: UInt8 = 0) {
        self.current = current; self.max = max; self.type = type
    }
}

public enum GetChecksumMode: Sendable {
    /// Matches MonitorControl Arm64DDC's Get VCP checksum quirk (omits 0x51).
    case appleSilicon
    case standard
}

public enum DDCPacket {
    public static func checksum(_ bytes: [UInt8], seed: UInt8) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    // IOAVService supplies source 0x51 via dataAddress, so it is not in this buffer.
    private static func request(_ payload: [UInt8], seed: UInt8 = 0x6e ^ 0x51) -> [UInt8] {
        let bytes = [UInt8(0x80 | payload.count)] + payload
        return bytes + [checksum(bytes, seed: seed)]
    }

    public static func get(_ vcp: UInt8, mode: GetChecksumMode = .appleSilicon) -> [UInt8] {
        request([0x01, vcp], seed: mode == .appleSilicon ? 0x6e : 0x6e ^ 0x51)
    }

    public static func set(_ vcp: UInt8, value: UInt16) -> [UInt8] {
        request([0x03, vcp, UInt8(value >> 8), UInt8(value & 0xff)])
    }

    public static func capabilities(offset: UInt16) -> [UInt8] {
        request([0xf3, UInt8(offset >> 8), UInt8(offset & 0xff)])
    }

    /// IOAVService returns a fixed-size buffer, not a received byte count.
    /// Only the declared frame participates in checksum; trailing bus padding is ignored.
    public static func payload(_ raw: [UInt8]) throws -> [UInt8] {
        guard raw.count >= 3 else { throw DDCError.invalid("truncated header") }
        guard raw[0] == 0x6e else { throw DDCError.invalid("invalid source address") }
        guard raw[1] & 0x80 != 0 else { throw DDCError.invalid("missing length flag") }
        let length = Int(raw[1] & 0x7f)
        guard length <= 35, raw.count >= length + 3 else {
            throw DDCError.invalid("invalid/truncated length: \(length)")
        }
        let frame = Array(raw.prefix(length + 3))
        guard checksum(frame, seed: 0x50) == 0 else { throw DDCError.invalid("checksum mismatch") }
        guard length > 0 else { throw DDCError.invalid("DDC null response") }
        return Array(frame[2..<(2 + length)])
    }

    public static func parseVCP(_ raw: [UInt8], expected: UInt8) throws -> VCPValue {
        let p = try payload(raw)
        guard p.count == 8 else { throw DDCError.invalid("Get VCP payload must be 8 bytes") }
        guard p[0] == 0x02 else { throw DDCError.invalid("not a Get VCP reply") }
        guard p[2] == expected else { throw DDCError.invalid("VCP code mismatch") }
        guard p[1] == 0 else { throw DDCError.invalid("monitor result code \(p[1]) (unsupported/error)") }
        guard p[3] <= 1 else { throw DDCError.invalid("invalid VCP type") }
        // Do not enforce current <= max: non-continuous and vendor codes can use these bytes differently.
        return VCPValue(current: UInt16(p[6]) << 8 | UInt16(p[7]),
                        max: UInt16(p[4]) << 8 | UInt16(p[5]), type: p[3])
    }

    public static func parseCapabilities(_ raw: [UInt8], expectedOffset: UInt16) throws -> CapabilityChunk {
        let p = try payload(raw)
        guard p.count >= 3, p[0] == 0xe3 else { throw DDCError.invalid("invalid capabilities reply") }
        let offset = UInt16(p[1]) << 8 | UInt16(p[2])
        guard offset == expectedOffset else { throw DDCError.invalid("capabilities offset mismatch") }
        return CapabilityChunk(offset: offset, bytes: Array(p.dropFirst(3)))
    }
}

public struct ReadAttempt: Sendable {
    public let number: Int
    public let raw: [UInt8]
    public let writeStatus: Int32
    public let readStatus: Int32?
    public let value: VCPValue?
    public let rejection: String?

    public init(number: Int, raw: [UInt8], writeStatus: Int32, readStatus: Int32?, vcp: UInt8) {
        self.number = number; self.raw = raw
        self.writeStatus = writeStatus; self.readStatus = readStatus
        if writeStatus != 0 || readStatus != 0 {
            value = nil; rejection = "I2C failure (write=\(writeStatus), read=\(readStatus.map(String.init) ?? "not attempted"))"
        } else {
            do { value = try DDCPacket.parseVCP(raw, expected: vcp); rejection = nil }
            catch { value = nil; rejection = String(describing: error) }
        }
    }
}

public struct ReadReport: Sendable {
    public let attempts: [ReadAttempt]
    public let accepted: VCPValue?
    public let agreement: Int
    public let validCount: Int
    public var provisional: Bool { accepted != nil && agreement == 1 }

    /// Strict majority among valid samples. A sole valid sample is provisional;
    /// no valid samples or a tie/conflict without a majority yields nil.
    public init(attempts: [ReadAttempt]) {
        self.attempts = attempts
        let values = attempts.compactMap(\.value)
        validCount = values.count
        let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
        if let winner = counts.first(where: { $0.value > values.count / 2 }) {
            accepted = winner.key; agreement = winner.value
        } else { accepted = nil; agreement = 0 }
    }
}

public struct CapabilityChunk: Equatable, Sendable {
    public let offset: UInt16
    public let bytes: [UInt8]
    public init(offset: UInt16, bytes: [UInt8]) { self.offset = offset; self.bytes = bytes }
}

public struct CapabilityProgress: Sendable {
    public let bytes: [UInt8]
    public let complete: Bool
    public var nextOffset: UInt16 { UInt16(bytes.count) }

    /// Rebuilds a contiguous stream, rejects gaps/duplicates and data after termination.
    /// Empty fragment or NUL terminates; a short nonempty fragment does NOT.
    public static func assemble(_ chunks: [CapabilityChunk]) throws -> CapabilityProgress {
        var bytes: [UInt8] = []
        var complete = false
        for chunk in chunks {
            guard !complete, Int(chunk.offset) == bytes.count else {
                throw DDCError.invalid("non-contiguous capabilities stream")
            }
            let data = Array(chunk.bytes.prefix { $0 != 0 })
            guard data.allSatisfy({ $0 < 0x80 }) else { throw DDCError.invalid("non-ASCII capabilities") }
            guard bytes.count + data.count <= Int(UInt16.max) else {
                throw DDCError.invalid("capabilities offset overflow")
            }
            bytes += data
            complete = chunk.bytes.isEmpty || data.count != chunk.bytes.count
        }
        return CapabilityProgress(bytes: bytes, complete: complete)
    }
}
