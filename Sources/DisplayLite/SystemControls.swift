import AppKit
@preconcurrency import ApplicationServices
import CoreAudio
import DDCKit

/// All UI/cache state lives on main. Foreign callbacks only enqueue main work.
@MainActor
final class SystemControls {
    private static weak var active: SystemControls?
    private let services = DisplayServices()
    private var builtin: [CGDirectDisplayID]?
    private var registered: CGDirectDisplayID?
    private var output = AudioEnvironment.defaultOutput()
    private var defaultOutputListenerAvailable = false
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice: AudioDeviceID = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fallbackRead: DispatchWorkItem?
    private var topologyWork: DispatchWorkItem?
    private var held: [MediaKey: MediaAction] = [:]
    var canControl = false
    var follow = true
    var action: ((MediaAction, Bool, Bool) -> Void)?
    var brightness: ((Double) -> Void)?
    var topologyWillChange: (() -> Void)?
    var topologyChanged: (() -> Void)?
    var statusChanged: (() -> Void)?
    private(set) var brightnessReadable = false
    var hasBuiltin: Bool { builtin?.isEmpty == false }
    private(set) var trusted = false
    var tapAvailable: Bool { tap != nil }
    var notificationsAvailable: Bool { registered != nil }

    func start() {
        SystemControls.active = self
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { SystemControls.active?.updateAudio() }
        }
        audioListener = listener
        var property = AudioEnvironment.address(kAudioHardwarePropertyDefaultOutputDevice)
        defaultOutputListenerAvailable = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &property, .main, listener) == noErr
        updateAudio()
        CGDisplayRegisterReconfigurationCallback(displayCallback, nil)
        updateDisplays()
        checkPermission()
    }

    func stop() {
        fallbackRead?.cancel(); topologyWork?.cancel()
        unregisterBrightness()
        CGDisplayRemoveReconfigurationCallback(displayCallback, nil)
        if let listener = audioListener {
            var property = AudioEnvironment.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
            removeDeviceListener()
        }
        destroyTap()
        SystemControls.active = nil
    }

    // Use an identical function pointer when registering/removing.
    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
        guard !flags.contains(.beginConfigurationFlag) else { return }
        DispatchQueue.main.async { SystemControls.active?.displayChanged() }
    }
    private var displayCallback: CGDisplayReconfigurationCallBack { Self.displayCallback }

    private func displayChanged() {
        canControl = false
        held.removeAll()
        topologyWillChange?()
        updateDisplays()
        // One bounded debounce per topology burst; never reschedules itself.
        topologyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.updateDisplays()
            self.topologyChanged?()
        }
        topologyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func removeDeviceListener() {
        guard listenedDevice != 0, let listener = audioListener else { return }
        var property = AudioEnvironment.address(kAudioObjectPropertySelectorWildcard,
                                               scope: kAudioObjectPropertyScopeWildcard,
                                               element: kAudioObjectPropertyElementWildcard)
        AudioObjectRemovePropertyListenerBlock(listenedDevice, &property, .main, listener)
        listenedDevice = 0
    }
    private func updateAudio() {
        output = AudioEnvironment.defaultOutput()
        guard output.id != listenedDevice else { return }
        removeDeviceListener()
        if output.id != 0, let listener = audioListener {
            var property = AudioEnvironment.address(kAudioObjectPropertySelectorWildcard,
                                                   scope: kAudioObjectPropertyScopeWildcard,
                                                   element: kAudioObjectPropertyElementWildcard)
            if AudioObjectAddPropertyListenerBlock(output.id, &property, .main, listener) == noErr {
                listenedDevice = output.id
            }
        }
    }

    private func unregisterBrightness() {
        if let registered { _ = services.unregister?(registered, registered) }
        registered = nil
    }
    private func updateDisplays() {
        fallbackRead?.cancel()
        builtin = DisplayEnvironment.builtinDisplays()
        let target = builtin?.first
        if registered != target {
            unregisterBrightness()
            if let target, let register = services.register, services.unregister != nil {
                let result = register(target, target, { _, _, _, _, _ in
                    // Never interpret the UInt32 observer token as an object pointer.
                    DispatchQueue.main.async { SystemControls.active?.sampleBrightness() }
                })
                if result == 0 { registered = target }
            }
        }
        sampleBrightness()
    }
    func sampleBrightness() {
        guard let id = builtin?.first else {
            brightnessReadable = false
            statusChanged?()
            return
        }
        let value = services.brightness(display: id)
        brightnessReadable = value != nil
        statusChanged?()
        if follow, let value { brightness?(value) }
    }
    private func brightnessKeyObserved() {
        guard follow, hasBuiltin, registered == nil else { return }
        fallbackRead?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sampleBrightness() }
        fallbackRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        checkPermission()
    }
    func checkPermission() {
        trusted = AXIsProcessTrusted()
        guard trusted else { destroyTap(); statusChanged?(); return }
        guard tap == nil else { statusChanged?(); return }
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                               options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
            let consumed = MainActor.assumeIsolated {
                guard let control = SystemControls.active else { return false }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = control.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return false
                }
                return control.handle(event)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil)
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            } else { destroyTap() }
        }
        statusChanged?()
    }
    private func destroyTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil; held.removeAll()
    }
    private func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
              let press = MediaKeyLogic.decode(subtype: Int(ns.subtype.rawValue), data1: ns.data1) else { return false }
        if press.key == .brightnessUp || press.key == .brightnessDown { brightnessKeyObserved() }
        let decision = MediaKeyLogic.action(key: press.key, outputIsDisplay: defaultOutputListenerAvailable && output.isDisplay,
                                          hasBuiltin: builtin == nil || hasBuiltin)
        // Re-evaluate routing on every event using cached state. Never swallow a
        // key after the output switches to speakers/headphones or the lid opens.
        guard canControl, decision != .passThrough else {
            if let previous = held.removeValue(forKey: press.key) { action?(previous, false, false) }
            return false
        }
        if press.isDown {
            // Do not take over a repeat whose initial down went to the system.
            guard !press.isRepeat || held[press.key] != nil else { return false }
            held[press.key] = decision
            action?(decision, true, press.isRepeat)
            return true
        }
        guard let previous = held.removeValue(forKey: press.key) else { return false }
        action?(previous, false, false)
        return true
    }
}
