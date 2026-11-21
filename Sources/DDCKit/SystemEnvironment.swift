import Foundation
import CoreGraphics
import CoreAudio
import ApplicationServices
import Darwin

public enum DisplayEnvironment {
    /// nil means enumeration failed; callers must not infer clamshell mode from failure.
    public static func builtinDisplays() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// Runtime-only linkage. Notification ABI follows Lunar's Lunar-Bridging-Header.h:
/// the observer is a UInt32 token, NOT an object pointer. Keep this handle open
/// for the process lifetime, including any late framework callbacks.
public final class DisplayServices {
    public typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    public typealias Register = @convention(c) (UInt32, UInt32, CFNotificationCallback) -> Int32
    public typealias Unregister = @convention(c) (UInt32, UInt32) -> Int32
    public let get: Get?
    public let register: Register?
    public let unregister: Unregister?
    public init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: T.self)
        }
        get = symbol("DisplayServicesGetBrightness", Get.self)
        register = symbol("DisplayServicesRegisterForBrightnessChangeNotifications", Register.self)
        unregister = symbol("DisplayServicesUnregisterForBrightnessChangeNotifications", Unregister.self)
    }
    public func brightness(display: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard let get, get(display, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return Double(value)
    }
}

public struct AudioOutputInfo: Sendable {
    public var id: AudioDeviceID = 0
    public var name = "unknown"
    public var transport: UInt32?
    /// nil means the query failed. Unknown must never swallow keys.
    public var hasSettableVolume: Bool?
    public var isDisplay: Bool {
        guard id != 0 else { return false }
        return transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI || hasSettableVolume == false
    }
    public var transportDescription: String {
        guard let transport else { return "unknown" }
        let bytes = [24, 16, 8, 0].map { UInt8((transport >> $0) & 255) }
        return "\(String(bytes: bytes, encoding: .ascii) ?? "????") (\(transport))"
    }
}

public enum AudioEnvironment {
    public static func address(_ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    private static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector), size = UInt32(MemoryLayout<UInt32>.size), value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    public static func defaultOutput() -> AudioOutputInfo {
        var result = AudioOutputInfo()
        guard let id = uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice), id != 0 else { return result }
        result.id = id
        result.transport = uint(id, kAudioDevicePropertyTransportType)
        var nameAddress = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &size, &name) == noErr,
           let name { result.name = name.takeRetainedValue() as String }

        // Inspect all output channels, not just master: headphones may expose
        // only left/right volume. A failed stream query is unknown, not fixed-volume.
        var streams = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
              streamSize >= MemoryLayout<AudioBufferList>.size else { return result }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &streams, 0, nil, &streamSize, storage) == noErr else { return result }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return result }
        var failed = false
        for channel in 0...channels {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyVolumeDecibels] {
                var property = address(selector, scope: kAudioDevicePropertyScopeOutput, element: UInt32(channel))
                guard AudioObjectHasProperty(id, &property) else { continue }
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(id, &property, &settable) != noErr { failed = true }
                else if settable.boolValue { result.hasSettableVolume = true; return result }
            }
        }
        result.hasSettableVolume = failed ? nil : false
        return result
    }
}

/// Read-only diagnostics: no notification registration, tap, prompt or DDC I/O.
public func environmentReport() -> String {
    let services = DisplayServices()
    let builtin = DisplayEnvironment.builtinDisplays()
    let audio = AudioEnvironment.defaultOutput()
    var lines = ["Built-in online: \(builtin.map { String(!$0.isEmpty) } ?? "unknown")"]
    for id in builtin ?? [] {
        lines.append("Built-in \(id) brightness: \(services.brightness(display: id).map(String.init(describing:)) ?? "unavailable")")
    }
    if builtin?.isEmpty != false { lines.append("Built-in brightness: unavailable (no online built-in display or enumeration failed)") }
    lines += [
        "DisplayServicesGetBrightness: \(services.get != nil)",
        "DisplayServicesRegisterForBrightnessChangeNotifications: \(services.register != nil)",
        "DisplayServicesUnregisterForBrightnessChangeNotifications: \(services.unregister != nil)",
        "Default output: \(audio.name) (id=\(audio.id))",
        "Transport: \(audio.transportDescription)",
        "Settable output volume: \(audio.hasSettableVolume.map(String.init) ?? "unknown")",
        "Output matches display heuristic: \(audio.isDisplay)",
        "AXIsProcessTrusted: \(AXIsProcessTrusted())"
    ]
    return lines.joined(separator: "\n")
}
