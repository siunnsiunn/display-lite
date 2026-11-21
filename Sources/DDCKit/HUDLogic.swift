public enum HUDSource: Sendable { case key, sync, slider }

public struct HUDContent: Equatable, Sendable {
    public let symbol: String
    public let value: UInt16
    public let progress: Double
}

/// Presentation policy only: no display reads, UI state, or timers.
public enum HUDLogic {
    public static func content(action: MediaAction, value: UInt16, maximum: UInt16,
                               muted: Bool, source: HUDSource) -> HUDContent? {
        guard source == .key else { return nil }
        let symbol: String
        let silent: Bool
        switch action {
        case .passThrough: return nil
        case .volume, .toggleMute:
            silent = muted
            symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness:
            silent = false
            symbol = "sun.max.fill"
        }
        return HUDContent(symbol: symbol, value: value,
                          progress: silent ? 0 : SliderLogic.position(value: value, maximum: maximum))
    }
}
