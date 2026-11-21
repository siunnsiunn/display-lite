/// Hardware-independent slider mapping and monotonic-time throttle decisions.
public enum SliderLogic {
    public static func maximum(reported: UInt16?, fallback: UInt16) -> UInt16 {
        guard let reported, reported > 0 else { return Swift.max(1, fallback) }
        return reported
    }

    public static func position(value: UInt16, maximum: UInt16) -> Double {
        Double(Swift.min(value, maximum)) / Double(Swift.max(1, maximum))
    }

    public static func value(position: Double, maximum: UInt16) -> UInt16 {
        guard position.isFinite else { return 0 }
        return UInt16((Swift.min(1, Swift.max(0, position)) * Double(maximum)).rounded())
    }

    /// Release always wins, even if unchanged or inside the throttle interval.
    public static func shouldWrite(now: Double, lastWrite: Double?, isFinal: Bool,
                                   interval: Double = 0.09) -> Bool {
        isFinal || lastWrite == nil || now - lastWrite! >= interval
    }
}
