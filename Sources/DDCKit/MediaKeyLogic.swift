/// Hardware-independent media-key policy. Values are NX_KEYTYPE_* constants.
public enum MediaKey: Int, CaseIterable, Sendable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}
public enum MediaAction: Equatable, Sendable {
    case passThrough, volume(Int), brightness(Int), toggleMute
}
public struct MediaKeyPress: Equatable, Sendable {
    public let key: MediaKey
    public let isDown: Bool
    public let isRepeat: Bool
}
public enum MediaKeyLogic {
    public static func decode(subtype: Int, data1: Int) -> MediaKeyPress? {
        guard subtype == 8, let key = MediaKey(rawValue: (data1 >> 16) & 0xffff) else { return nil }
        let state = (data1 >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        return MediaKeyPress(key: key, isDown: state == 0x0a, isRepeat: data1 & 1 != 0)
    }
    public static func action(key: MediaKey, outputIsDisplay: Bool, hasBuiltin: Bool) -> MediaAction {
        switch key {
        case .volumeUp: return outputIsDisplay ? .volume(1) : .passThrough
        case .volumeDown: return outputIsDisplay ? .volume(-1) : .passThrough
        case .mute: return outputIsDisplay ? .toggleMute : .passThrough
        case .brightnessUp: return hasBuiltin ? .passThrough : .brightness(1)
        case .brightnessDown: return hasBuiltin ? .passThrough : .brightness(-1)
        }
    }
    public static func step(value: UInt16, maximum: UInt16, direction: Int) -> UInt16 {
        let increment = Int((Double(maximum) / 16).rounded())
        let delta = direction == 0 ? 0 : direction > 0 ? increment : -increment
        return UInt16(min(Int(maximum), max(0, Int(min(value, maximum)) + delta)))
    }
    public static func brightness(_ value: Double, maximum: UInt16) -> UInt16? {
        guard value.isFinite else { return nil }
        return SliderLogic.value(position: value, maximum: maximum)
    }
    public static func toggledMute(_ value: UInt16) -> UInt16? {
        value == 1 ? 2 : value == 2 ? 1 : nil
    }
}
