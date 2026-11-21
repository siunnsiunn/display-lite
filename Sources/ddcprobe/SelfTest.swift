import DDCKit

private func check(_ condition: @autoclosure () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    guard try condition() else { throw DDCError.invalid("selftest failed at \(file):\(line)") }
}
private func rejects<T>(_ operation: () throws -> T, file: StaticString = #fileID, line: UInt = #line) throws {
    do { _ = try operation() }
    catch { return }
    throw DDCError.invalid("selftest expected rejection at \(file):\(line)")
}

struct ProtocolChecks {
    func frame(_ payload: [UInt8]) -> [UInt8] {
        let bytes = [0x6e, UInt8(0x80 | payload.count)] + payload
        return bytes + [DDCPacket.checksum(bytes, seed: 0x50)]
    }
    func vcp(_ current: UInt8 = 40, max: UInt8 = 100, code: UInt8 = 0x10) -> [UInt8] {
        frame([2, 0, code, 0, 0, max, 0, current])
    }
    func attempt(_ raw: [UInt8], write: Int32 = 0, read: Int32? = 0) -> ReadAttempt {
        ReadAttempt(number: 1, raw: raw, writeStatus: write, readStatus: read, vcp: 0x10)
    }
    func testKnownRequestVectors() throws {
        try check(DDCPacket.get(0x10, mode: .standard) == [0x82, 1, 0x10, 0xac])
        try check(DDCPacket.get(0x10) == [0x82, 1, 0x10, 0xfd])
        try check(DDCPacket.set(0x10, value: 50) == [0x84, 3, 0x10, 0, 50, 0x9a])
        try check(DDCPacket.capabilities(offset: 0x1234) == [0x83, 0xf3, 0x12, 0x34, 0x69])
        try check(DDCPacket.set(0x60, value: 0x1234).dropLast() == [0x84, 3, 0x60, 0x12, 0x34])
    }
    func testKnownReplyAndZero() throws {
        let raw: [UInt8] = [0x6e, 0x88, 2, 0, 0x10, 0, 0, 100, 0, 40, 0xe8]
        try check(try DDCPacket.parseVCP(raw, expected: 0x10) == VCPValue(current: 40, max: 100))
        try check(try DDCPacket.parseVCP(vcp(0), expected: 0x10).current == 0)
        try check(try DDCPacket.parseVCP(frame([2, 0, 0x10, 1, 0x12, 0x34, 0xab, 0xcd]), expected: 0x10) == VCPValue(current: 0xabcd, max: 0x1234, type: 1))
    }
    func testMalformedReplies() throws {
        var badChecksum = vcp(); badChecksum[10] ^= 1
        var wrongSource = vcp(); wrongSource[0] = 0
        var wrongFlag = vcp(); wrongFlag[1] = 8
        let invalid: [[UInt8]] = [[], [0x6e], Array(vcp().dropLast()), badChecksum, wrongSource, wrongFlag,
            frame([]), frame([2, 0, 0x10]), vcp(code: 0x12), frame([2, 1, 0x10, 0, 0, 100, 0, 40]),
            frame([3, 0, 0x10, 0, 0, 100, 0, 40]), frame([2, 0, 0x10, 2, 0, 100, 0, 40]),
            [0x6e, 0xff] + Array(repeating: 0, count: 128)]
        for raw in invalid { try rejects { try DDCPacket.parseVCP(raw, expected: 0x10) } }
    }
    func testSelection() throws {
        try check(ReadReport(attempts: []).accepted == nil)
        try check(ReadReport(attempts: [attempt([])]).accepted == nil)
        let single = ReadReport(attempts: [attempt([]), attempt(vcp())])
        try check(single.provisional)
        try check(single.accepted?.current == 40)
        try check(ReadReport(attempts: [attempt(vcp(0)), attempt(vcp(40))]).accepted == nil)
        let report = ReadReport(attempts: [attempt(vcp(0)), attempt(vcp(40)), attempt(vcp(40)), attempt([])])
        try check(report.accepted?.current == 40)
        try check(report.agreement == 2)
        try check(report.validCount == 3)
        try check(!report.provisional)
        try check(ReadReport(attempts: [attempt(vcp(0)), attempt(vcp(0)), attempt(vcp(40))]).accepted?.current == 0)
        try check(ReadReport(attempts: [attempt(vcp(1)), attempt(vcp(2)), attempt(vcp(3))]).accepted == nil)
        try check(attempt(vcp(), write: -1, read: nil).value == nil)
        try check(attempt(vcp(), read: -1).value == nil)
    }
    func testCapabilityChunks() throws {
        let first = try DDCPacket.parseCapabilities(frame([0xe3, 0, 0] + Array("(vcp(".utf8)) + [0xff, 0xff], expectedOffset: 0)
        var progress = try CapabilityProgress.assemble([first])
        try check(!progress.complete)
        try check(progress.nextOffset == 5)
        let second = try DDCPacket.parseCapabilities(frame([0xe3, 0, 5] + Array("10))".utf8)), expectedOffset: 5)
        progress = try CapabilityProgress.assemble([first, second, CapabilityChunk(offset: 9, bytes: [])])
        try check(progress.complete)
        try check(String(decoding: progress.bytes, as: UTF8.self) == "(vcp(10))")
        let nul = try CapabilityProgress.assemble([CapabilityChunk(offset: 0, bytes: [65, 0, 255])])
        try check(nul.complete); try check(nul.bytes == [65])
        try rejects { try DDCPacket.parseCapabilities(frame([0xe3, 0, 1]), expectedOffset: 0) }
        try rejects { try DDCPacket.parseCapabilities(frame([0x02, 0, 0]), expectedOffset: 0) }
        try rejects { try DDCPacket.parseCapabilities(frame([0xe3, 0]), expectedOffset: 0) }
        try rejects { try CapabilityProgress.assemble([first, first]) }
        try rejects { try CapabilityProgress.assemble([CapabilityChunk(offset: 1, bytes: [])]) }
        try rejects { try CapabilityProgress.assemble([CapabilityChunk(offset: 0, bytes: []), first]) }
        try rejects { try CapabilityProgress.assemble([CapabilityChunk(offset: 0, bytes: [255])]) }
        try rejects { try CapabilityProgress.assemble([CapabilityChunk(offset: 0, bytes: Array(repeating: 65, count: 65536))]) }
    }
    func testFullCapabilityFragment() throws {
        let data = Array(repeating: UInt8(65), count: 32)
        let chunk = try DDCPacket.parseCapabilities(frame([0xe3, 0, 0] + data), expectedOffset: 0)
        try check(chunk.bytes == data)
        try check(try CapabilityProgress.assemble([chunk]).nextOffset == 32)
        try check(try !CapabilityProgress.assemble([chunk]).complete)
        var corrupt = frame([0xe3, 0, 0] + data)
        corrupt[10] ^= 1
        try rejects { try DDCPacket.parseCapabilities(corrupt, expectedOffset: 0) }
    }
    func testCapabilityBeyondByteOffset() throws {
        let bytes = Array(repeating: UInt8(65), count: 256)
        let chunk = try DDCPacket.parseCapabilities(frame([0xe3, 1, 0, 66, 0]), expectedOffset: 256)
        let progress = try CapabilityProgress.assemble([CapabilityChunk(offset: 0, bytes: bytes), chunk])
        try check(progress.complete); try check(progress.bytes.count == 257)
    }
}

func runSelfTests() throws {
    let tests = ProtocolChecks()
    let groups: [(String, () throws -> Void)] = [
        ("known request vectors", tests.testKnownRequestVectors),
        ("reply vectors, zero, 16-bit values", tests.testKnownReplyAndZero),
        ("malformed replies", tests.testMalformedReplies),
        ("consensus and I2C failures", tests.testSelection),
        ("capability assembly and termination", tests.testCapabilityChunks),
        ("full 32-byte capability fragments", tests.testFullCapabilityFragment),
        ("capability offsets above 255", tests.testCapabilityBeyondByteOffset)
    ]
    for (name, test) in groups { try test(); print("PASS: \(name)") }
    print("All \(groups.count) pure-function test groups passed (no hardware access).")
}
