/// BenQ MA270U modes in menu order. Edit this table to change the available modes.
public enum ColorModeLogic {
    public static let vcp: UInt8 = 0xDC
    public static let modes: [(value: UInt16, name: String)] = [
        (0x0F, "M-book"), (0x0A, "sRGB"), (0x22, "Display P3"),
        (0x12, "使用者"), (0x28, "遊戲"), (0x32, "劇院")
    ]

    /// Unknown or failed readings select no menu item.
    public static func selectedIndex(for value: UInt16?) -> Int? {
        guard let value else { return nil }
        return modes.firstIndex { $0.value == value }
    }
}
