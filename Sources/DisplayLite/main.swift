import AppKit
import DDCKit

private let controls: [(name: String, code: UInt8, fallback: UInt16)] = [
    ("亮度", 0x10, 100), ("對比", 0x12, 100), ("音量", 0x62, 50)
]

private struct Reading: Sendable {
    var value: UInt16 = 0
    var maximum: UInt16
    var known = false
}

/// All mutable state and non-Sendable DDCDisplay instances are confined to queue.
/// Only Sendable snapshots cross back to the main thread.
private final class DDCWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DisplayLite.DDC", qos: .userInitiated)
    private var display: DDCDisplay?
    private var readings = controls.map { Reading(maximum: $0.fallback) }
    private var lastWrite: Double?

    func refresh(completion: @escaping @MainActor @Sendable (String, Bool, [Reading], UInt16?) -> Void) {
        queue.async { [self] in
            let candidates = (try? DDCDisplay.list())?.filter { $0.info.available } ?? []
            let selected = candidates.count == 1 ? candidates[0] : nil
            if selected?.info.registryID != display?.info.registryID {
                readings = controls.map { Reading(maximum: $0.fallback) }
                lastWrite = nil
            }
            display = selected
            var title = candidates.count > 1 ? "偵測到多個螢幕，暫不支援選擇" : "沒有偵測到可控制的螢幕"
            var colorMode: UInt16?
            if let display {
                title = display.info.name
                // Some monitors reject Get immediately after Set. This is a bounded
                // background delay during menu-open work, never an idle timer.
                if let lastWrite {
                    let remaining = 0.2 - (ProcessInfo.processInfo.systemUptime - lastWrite)
                    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
                }
                for index in controls.indices {
                    if let result = try? display.read(vcp: controls[index].code) {
                        readings[index] = Reading(value: result.current,
                            maximum: SliderLogic.maximum(reported: result.max, fallback: controls[index].fallback),
                            known: true)
                    } else { readings[index].known = false }
                }
                colorMode = (try? display.read(vcp: ColorModeLogic.vcp))?.current
            } else {
                for index in readings.indices { readings[index].known = false }
            }
            let snapshot = readings
            let enabled = display != nil
            let message = title
            let modeSnapshot = colorMode
            DispatchQueue.main.async { completion(message, enabled, snapshot, modeSnapshot) }
        }
    }

    func writeColorMode(value: UInt16,
                        completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            var succeeded = false
            if let display {
                lastWrite = ProcessInfo.processInfo.systemUptime
                do {
                    try display.write(vcp: ColorModeLogic.vcp, value: value, repetitions: 1)
                    succeeded = true
                } catch { /* Clear the optimistic check on transport failure. */ }
            }
            // No readback: changing mode can temporarily make the monitor reject Get.
            let result = succeeded
            DispatchQueue.main.async { completion(result) }
        }
    }

    func write(index: Int, value: UInt16, final: Bool,
               completion: @escaping @MainActor @Sendable (Reading) -> Void) {
        queue.async { [self] in
            guard let display else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard SliderLogic.shouldWrite(now: now, lastWrite: lastWrite, isFinal: final) else { return }
            lastWrite = now
            do {
                try display.write(vcp: controls[index].code, value: value, repetitions: 1)
                readings[index].value = value
                readings[index].known = true
            } catch { readings[index].known = false }
            let snapshot = readings[index]
            DispatchQueue.main.async { completion(snapshot) }
        }
    }
}

@MainActor
private final class TrackingSlider: NSSlider {
    var finished: (() -> Void)?
    var tracking = false
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        tracking = true
        super.mouseDown(with: event)
        tracking = false
        finished?() // NSSlider's tracking loop has consumed mouse-up.
    }
}

@MainActor
private final class SliderRow: NSView {
    let slider = TrackingSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "—")
    var maximum: UInt16
    var revision = 0
    var changed: ((UInt16, Bool) -> Void)?

    init(name: String, maximum: UInt16) {
        self.maximum = maximum
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 62))
        let label = NSTextField(labelWithString: name)
        label.frame = NSRect(x: 18, y: 36, width: 130, height: 20)
        valueLabel.frame = NSRect(x: 160, y: 36, width: 100, height: 20)
        valueLabel.alignment = .right
        slider.frame = NSRect(x: 18, y: 8, width: 244, height: 24)
        slider.isContinuous = true
        slider.isEnabled = false
        slider.target = self
        slider.action = #selector(slid)
        slider.setAccessibilityLabel(name)
        slider.finished = { [weak self] in self?.submit(final: true) }
        addSubview(label); addSubview(valueLabel); addSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func slid() { submit(final: !slider.tracking) }
    private func submit(final: Bool) {
        revision += 1
        let value = SliderLogic.value(position: slider.doubleValue, maximum: maximum)
        valueLabel.stringValue = "\(value) / \(maximum)"
        changed?(value, final)
    }
    func apply(_ reading: Reading) {
        maximum = reading.maximum
        slider.doubleValue = SliderLogic.position(value: reading.value, maximum: maximum)
        valueLabel.stringValue = reading.known ? "\(reading.value) / \(maximum)" : "—"
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let worker = DDCWorker()
    private let info = NSMenuItem(title: "開啟選單以偵測螢幕", action: nil, keyEquivalent: "")
    private var rows: [SliderRow] = []
    private var refreshing = false
    private var colorModeItems: [NSMenuItem] = []
    private var colorModeRevision = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "DisplayLite") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else { statusItem.button?.title = "DisplayLite" }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        info.isEnabled = false
        menu.addItem(info)
        for (index, control) in controls.enumerated() {
            let row = SliderRow(name: control.name, maximum: control.fallback)
            row.changed = { [weak self, weak row] value, final in
                guard let self, let row else { return }
                let revision = row.revision
                self.worker.write(index: index, value: value, final: final) { [weak row] reading in
                    guard let row, row.revision == revision else { return }
                    row.apply(reading)
                }
            }
            rows.append(row)
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let colorMenu = NSMenu()
        colorMenu.autoenablesItems = false
        for (index, mode) in ColorModeLogic.modes.enumerated() {
            let item = NSMenuItem(title: mode.name, action: #selector(selectColorMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = false
            colorModeItems.append(item)
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: "色彩模式", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func applyColorMode(_ value: UInt16?) {
        let selected = ColorModeLogic.selectedIndex(for: value)
        for (index, item) in colorModeItems.enumerated() {
            item.state = index == selected ? .on : .off
        }
    }

    @objc private func selectColorMode(_ sender: NSMenuItem) {
        guard !refreshing, sender.isEnabled,
              ColorModeLogic.modes.indices.contains(sender.tag) else { return }
        let value = ColorModeLogic.modes[sender.tag].value
        colorModeRevision += 1
        let revision = colorModeRevision
        applyColorMode(value)
        worker.writeColorMode(value: value) { [weak self] succeeded in
            guard let self, self.colorModeRevision == revision else { return }
            if !succeeded { self.applyColorMode(nil) }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard !refreshing else { return } // Coalesce reopen while the same read is in flight.
        refreshing = true
        info.title = "正在讀取螢幕…"
        for row in rows { row.slider.isEnabled = false; row.revision += 1 }
        colorModeRevision += 1
        for item in colorModeItems { item.isEnabled = false }
        worker.refresh { [weak self] title, enabled, readings, colorMode in
            guard let self else { return }
            self.refreshing = false
            self.info.title = title
            self.applyColorMode(colorMode)
            for item in self.colorModeItems { item.isEnabled = enabled }
            for (row, reading) in zip(self.rows, readings) {
                row.apply(reading)
                row.slider.isEnabled = enabled
            }
        }
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
