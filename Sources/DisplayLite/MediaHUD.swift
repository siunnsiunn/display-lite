import AppKit
import DDCKit

@MainActor
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MediaHUD {
    private let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let icon = NSImageView(frame: NSRect(x: 16, y: 16, width: 24, height: 24))
    private let progress = NSProgressIndicator(frame: NSRect(x: 52, y: 24, width: 106, height: 8))
    private let number = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    init() {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 56))
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop
        icon.contentTintColor = .labelColor
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        number.frame = NSRect(x: 166, y: 18, width: 42, height: 20)
        number.alignment = .right
        number.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        number.textColor = .labelColor
        backdrop.addSubview(icon)
        backdrop.addSubview(progress)
        backdrop.addSubview(number)
    }

    func show(_ content: HUDContent, display: DisplayInfo) {
        hideWork?.cancel()
        generation += 1
        let token = generation
        let external = NSScreen.screens.filter {
            guard let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
        let matched = external.first { screen in
            guard let expected = display.edidUUID,
                  let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
            return (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(expected) == .orderedSame
        }
        guard let screen = matched ?? (external.count == 1 ? external.first : nil) ?? NSScreen.main else { return }
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - 110, y: frame.minY + frame.height / 8))
        icon.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)
        progress.doubleValue = content.progress
        number.stringValue = String(content.value)
        // Cancel any in-flight fade before presenting the next key's value.
        panel.contentView?.layer?.removeAllAnimations()
        panel.contentView?.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.hideWork = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.panel.contentView?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func hide() {
        generation += 1
        hideWork?.cancel()
        hideWork = nil
        panel.contentView?.layer?.removeAllAnimations()
        panel.orderOut(nil)
    }
}
