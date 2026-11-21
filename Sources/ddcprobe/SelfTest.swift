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
    func testMediaPolicy() throws {
        for output in [false, true] {
            for builtin in [false, true] {
                try check(MediaKeyLogic.action(key: .volumeUp, outputIsDisplay: output, hasBuiltin: builtin) == (output ? .volume(1) : .passThrough))
                try check(MediaKeyLogic.action(key: .volumeDown, outputIsDisplay: output, hasBuiltin: builtin) == (output ? .volume(-1) : .passThrough))
                try check(MediaKeyLogic.action(key: .mute, outputIsDisplay: output, hasBuiltin: builtin) == (output ? .toggleMute : .passThrough))
                try check(MediaKeyLogic.action(key: .brightnessUp, outputIsDisplay: output, hasBuiltin: builtin) == (builtin ? .passThrough : .brightness(1)))
                try check(MediaKeyLogic.action(key: .brightnessDown, outputIsDisplay: output, hasBuiltin: builtin) == (builtin ? .passThrough : .brightness(-1)))
            }
        }
        for key in MediaKey.allCases {
            let down = MediaKeyLogic.decode(subtype: 8, data1: key.rawValue << 16 | 0x0a00)
            let repeated = MediaKeyLogic.decode(subtype: 8, data1: key.rawValue << 16 | 0x0a01)
            let up = MediaKeyLogic.decode(subtype: 8, data1: key.rawValue << 16 | 0x0b00)
            try check(down?.key == key && down?.isDown == true && down?.isRepeat == false)
            try check(repeated?.isDown == true && repeated?.isRepeat == true)
            try check(up?.key == key && up?.isDown == false)
        }
        try check(MediaKeyLogic.decode(subtype: 7, data1: 0x0a00) == nil)
        try check(MediaKeyLogic.decode(subtype: 8, data1: 99 << 16 | 0x0a00) == nil)
        try check(MediaKeyLogic.decode(subtype: 8, data1: 0x0c00) == nil)
        try check(MediaKeyLogic.toggledMute(1) == 2)
        try check(MediaKeyLogic.toggledMute(2) == 1)
        try check(MediaKeyLogic.toggledMute(0) == nil)
        try check(MediaKeyLogic.toggledMute(65535) == nil)
    }
    func testMediaStepsAndSync() throws {
        try check(MediaKeyLogic.step(value: 25, maximum: 50, direction: 1) == 28)
        try check(MediaKeyLogic.step(value: 25, maximum: 50, direction: -1) == 22)
        try check(MediaKeyLogic.step(value: 50, maximum: 100, direction: 1) == 56)
        try check(MediaKeyLogic.step(value: 0, maximum: 100, direction: -1) == 0)
        try check(MediaKeyLogic.step(value: 49, maximum: 50, direction: 1) == 50)
        try check(MediaKeyLogic.step(value: 1, maximum: 50, direction: -1) == 0)
        try check(MediaKeyLogic.step(value: 65535, maximum: 65535, direction: 1) == 65535)
        try check(MediaKeyLogic.step(value: 65535, maximum: 0, direction: 1) == 0)
        try check(MediaKeyLogic.step(value: 65535, maximum: 50, direction: -1) == 47)
        try check(MediaKeyLogic.step(value: 10, maximum: 50, direction: 0) == 10)
        for maximum: UInt16 in [0, 50, 100, 65535] {
            try check(MediaKeyLogic.brightness(0, maximum: maximum) == 0)
            try check(MediaKeyLogic.brightness(1, maximum: maximum) == maximum)
            try check(MediaKeyLogic.brightness(-1, maximum: maximum) == 0)
            try check(MediaKeyLogic.brightness(2, maximum: maximum) == maximum)
        }
        try check(MediaKeyLogic.brightness(0.505, maximum: 100) == 51)
        try check(MediaKeyLogic.brightness(0.5, maximum: 50) == 25)
        try check(MediaKeyLogic.brightness(.nan, maximum: 100) == nil)
        try check(MediaKeyLogic.brightness(.infinity, maximum: 100) == nil)
        // Key intent accumulates independently of admitted writes; release sends 43.
        var desired: UInt16 = 25
        var last: Double?
        var sent: [UInt16] = []
        for now in [0.0, 0.02, 0.04, 0.06, 0.08, 0.10] {
            desired = MediaKeyLogic.step(value: desired, maximum: 50, direction: 1)
            if SliderLogic.shouldWrite(now: now, lastWrite: last, isFinal: false) {
                sent.append(desired); last = now
            }
        }
        if SliderLogic.shouldWrite(now: 0.11, lastWrite: last, isFinal: true) { sent.append(desired) }
        try check(sent == [28, 43, 43])
    }
    func testSliderLogic() throws {
        try check(SliderLogic.maximum(reported: nil, fallback: 50) == 50)
        try check(SliderLogic.maximum(reported: 0, fallback: 100) == 100)
        try check(SliderLogic.maximum(reported: 75, fallback: 100) == 75)
        for maximum: UInt16 in [50, 75, 100, 65535] {
            for value: UInt16 in [0, maximum / 2, maximum] {
                try check(SliderLogic.value(position: SliderLogic.position(value: value, maximum: maximum), maximum: maximum) == value)
            }
        }
        try check(SliderLogic.value(position: 0.5, maximum: 50) == 25)
        try check(SliderLogic.value(position: -1, maximum: 100) == 0)
        try check(SliderLogic.value(position: 2, maximum: 50) == 50)
        try check(SliderLogic.value(position: .nan, maximum: 50) == 0)
        try check(SliderLogic.position(value: 80, maximum: 50) == 1)
        try check(SliderLogic.position(value: 1, maximum: 0) == 0)
    }
    func testColorModes() throws {
        let expected: [(UInt16, String)] = [
            (15, "M-book"), (10, "sRGB"), (34, "Display P3"),
            (18, "使用者"), (40, "遊戲"), (50, "劇院")
        ]
        try check(ColorModeLogic.vcp == 0xDC)
        try check(ColorModeLogic.modes.count == expected.count)
        for (index, mode) in expected.enumerated() {
            try check(ColorModeLogic.modes[index].value == mode.0)
            try check(ColorModeLogic.modes[index].name == mode.1)
            try check(ColorModeLogic.selectedIndex(for: mode.0) == index)
        }
        for value: UInt16 in [0, 0x23, 0x27, 0xFFFF] {
            try check(ColorModeLogic.selectedIndex(for: value) == nil)
        }
        try check(ColorModeLogic.selectedIndex(for: nil) == nil)
    }
    func testThrottle() throws {
        try check(SliderLogic.shouldWrite(now: 0, lastWrite: nil, isFinal: false))
        try check(!SliderLogic.shouldWrite(now: 0.08, lastWrite: 0, isFinal: false))
        try check(SliderLogic.shouldWrite(now: 0.09, lastWrite: 0, isFinal: false))
        try check(SliderLogic.shouldWrite(now: 0.01, lastWrite: 0, isFinal: true))
        try check(SliderLogic.shouldWrite(now: 0, lastWrite: 0, isFinal: true))
        // A burst admits only the first and the event after 90ms, plus release.
        var last: Double?
        var admitted = 0
        for now in [0.0, 0.02, 0.04, 0.06, 0.08, 0.10] {
            if SliderLogic.shouldWrite(now: now, lastWrite: last, isFinal: false) {
                last = now; admitted += 1
            }
        }
        try check(admitted == 2)
        try check(SliderLogic.shouldWrite(now: 0.11, lastWrite: last, isFinal: true))
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
        ("media key decoding, routing and mute", tests.testMediaPolicy),
        ("media steps, clamp, sync mapping and final intent", tests.testMediaStepsAndSync),
        ("slider mapping and reported maxima", tests.testSliderLogic),
        ("color mode mapping and unknown readings", tests.testColorModes),
        ("throttle and final release", tests.testThrottle),
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
