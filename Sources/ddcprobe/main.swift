import Foundation
import DDCKit
import Darwin

let usage = """
Usage:
  ddcprobe selftest
  ddcprobe env
  ddcprobe list
  ddcprobe get <hex-vcp> [--tries N] [--standard-checksum] [--display registry-id]
  ddcprobe set <hex-vcp> <decimal-value> [--display registry-id]
  ddcprobe caps [--display registry-id]
  ddcprobe scan [--standard-checksum] [--display registry-id]
Hex VCP: 10 or 0x10. With multiple endpoints, --display is required.
"""

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
func run() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--help"] || args == ["help"] { print(usage); return }
    if args == ["selftest"] { try runSelfTests(); return }
    if args == ["env"] { print(environmentReport()); return }
    let command = args.removeFirst()
    guard ["list", "get", "set", "caps", "scan"].contains(command) else { throw DDCError.invalid(usage) }
    var displayID: UInt64?
    var tries = 5
    var mode: GetChecksumMode = .appleSilicon
    var positional: [String] = []
    var seen = Set<String>()
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg.hasPrefix("--") {
            guard seen.insert(arg).inserted else { throw DDCError.invalid("duplicate option: \(arg)") }
            switch arg {
            case "--display":
                guard command != "list", index + 1 < args.count, let id = UInt64(args[index + 1]) else {
                    throw DDCError.invalid("--display requires a decimal registry ID")
                }
                displayID = id; index += 1
            case "--tries":
                guard command == "get", index + 1 < args.count, let n = Int(args[index + 1]), (1...1000).contains(n) else {
                    throw DDCError.invalid("get --tries requires 1...1000")
                }
                tries = n; index += 1
            case "--standard-checksum":
                guard command == "get" || command == "scan" else { throw DDCError.invalid("checksum option is for get/scan") }
                mode = .standard
            default: throw DDCError.invalid("unknown option: \(arg)")
            }
        } else { positional.append(arg) }
        index += 1
    }
    let expectedCount = command == "get" ? 1 : command == "set" ? 2 : 0
    guard positional.count == expectedCount else { throw DDCError.invalid(usage) }
    var vcp: UInt8 = 0
    var value: UInt16 = 0
    if command == "get" || command == "set" {
        let input = positional[0].lowercased()
        let digits = input.hasPrefix("0x") ? String(input.dropFirst(2)) : input
        guard !digits.isEmpty, digits.allSatisfy({ $0.isHexDigit }), let parsed = UInt8(digits, radix: 16) else {
            throw DDCError.invalid("VCP must be hexadecimal 00...FF")
        }
        vcp = parsed
    }
    if command == "set" {
        guard !positional[1].isEmpty, positional[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let parsed = UInt16(positional[1]) else { throw DDCError.invalid("value must be decimal 0...65535") }
        value = parsed
    }
    let displays = try DDCDisplay.list()
    if command == "list" {
        if displays.isEmpty { print("No external DCPAVServiceProxy endpoints found.") }
        for display in displays {
            let i = display.info
            print("\(i.name) | id=\(i.registryID) | available=\(i.available)")
            print("  manufacturer=\(i.manufacturer ?? "unknown") serial=\(i.serial ?? "unknown") EDID UUID=\(i.edidUUID ?? "unknown")")
            print("  \(i.registryPath)")
        }
        return
    }
    let display: DDCDisplay
    if let displayID {
        guard let found = displays.first(where: { $0.info.registryID == displayID }) else { throw DDCError.invalid("display ID not found; run list") }
        display = found
    } else {
        guard displays.count == 1 else { throw DDCError.invalid("found \(displays.count) endpoints; run list and use --display <registry-id>") }
        display = displays[0]
    }
    switch command {
    case "get":
        let report = try display.readReport(vcp: vcp, options: ReadOptions(tries: tries, checksumMode: mode)) { attempt in
            var message = "attempt \(attempt.number): raw=[\(hex(attempt.raw))] write=\(attempt.writeStatus) read=\(attempt.readStatus.map(String.init) ?? "skipped")"
            if let value = attempt.value { message += " current=\(value.current) max=\(value.max) type=\(value.type)" }
            if let rejection = attempt.rejection { message += " rejected: \(rejection)" }
            print(message)
        }
        guard let accepted = report.accepted else { throw DDCError.invalid("no accepted value (\(report.validCount) valid replies; no majority or none valid)") }
        print("accepted: current=\(accepted.current) max=\(accepted.max) agreement=\(report.agreement)/\(report.validCount)\(report.provisional ? " provisional (single valid sample)" : "")")
    case "set":
        try display.write(vcp: vcp, value: value)
        print("Sent Set VCP twice; monitor application is not verified.")
    case "caps": print(try display.capabilities())
    case "scan":
        var found = 0
        for code in UInt16(0)...UInt16(255) {
            let report = try display.readReport(vcp: UInt8(code), options: ReadOptions(tries: 3, checksumMode: mode))
            if let value = report.accepted {
                found += 1
                print(String(format: "0x%02X", code) + " current=\(value.current) max=\(value.max) agreement=\(report.agreement)/\(report.validCount)\(report.provisional ? " provisional" : "")")
            } else if report.validCount > 0 {
                let values = report.attempts.compactMap(\.value).map { "\($0.current)/\($0.max)" }.joined(separator: ", ")
                print(String(format: "0x%02X", code) + " conflicting valid current/max: [\(values)] (not accepted)")
            }
        }
        print("Scan complete: \(found) accepted codes. Only Get VCP requests were sent.")
    default: break
    }
}

do { try run() }
catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
