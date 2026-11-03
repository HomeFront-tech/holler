import AppKit
import ApplicationServices

final class Hotkeys {
    static let syntheticTag: Int64 = 0x484F4C4C // "HOLL": marks keystrokes Holler posts itself
    var onAction: (HotkeyMachine.Action) -> Void = { _ in }
    private var machine = HotkeyMachine()
    private let lock = NSLock()
    private var frontmost: String?
    private var excludedApps: Set<String> = []
    private var lastExists = false
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var starting = false
    private var observer: NSObjectProtocol?
    private var generation = 0
    init() {
        refreshFrontmost()
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refreshFrontmost()
        }
    }
    private func refreshFrontmost() {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let excluded = Set(UserDefaults.standard.stringArray(forKey: "fnExcludedApps") ?? [])
        lock.lock(); frontmost = bundle; excludedApps = excluded; lock.unlock()
    }
    func setLastExists(_ value: Bool) { lock.lock(); lastExists = value; lock.unlock() }
    func completed() { _ = handle(.completed) }
    private func handle(_ event: HotkeyMachine.Event) -> Bool {
        lock.lock()
        let result = machine.handle(event, now: ProcessInfo.processInfo.systemUptime, frontmostBundleID: frontmost, hasLastText: lastExists, excludedApps: excludedApps)
        lock.unlock()
        if result.actions.contains(.prepare) {
            // Only a pending hold needs a timer; idle costs no polling wakeups.
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + HotkeyMachine.holdThreshold, 0, 0, 0) { _ in _ = self.handle(.tick) }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        }
        for action in result.actions { DispatchQueue.main.async { self.onAction(action) } }
        return result.swallow
    }
    @discardableResult func start() -> Bool {
        lock.lock()
        if tap != nil || starting { let ready = tap != nil; lock.unlock(); return ready }
        lock.unlock()
        // An active (filtering) session tap and posting Cmd+V both come with Accessibility; Input Monitoring is only
        // needed for listen-only taps, so don't block on it.
        guard AXIsProcessTrusted() else { return false }
        lock.lock(); starting = true; generation += 1; let gen = generation; lock.unlock()
        Thread.detachNewThread { [self] in
            // An active tap must have its own run loop; UI or speech work cannot stall key delivery.
            let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            let callback: CGEventTapCallBack = { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // A release may have been lost while disabled; cancel before accepting another hold.
                    // Events were lost while disabled: resync Fn with the real keyboard and forget swallow pairs.
                    _ = owner.handle(.reset(fnDown: CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)))
                    DispatchQueue.main.async { owner.onAction(.cancel) }
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    Log.event("event tap re-enabled")
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == Hotkeys.syntheticTag { return Unmanaged.passUnretained(event) }
                let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let swallow: Bool
                switch type {
                case .flagsChanged where code == 63:
                    swallow = owner.handle(.fn(down: event.flags.contains(.maskSecondaryFn)))
                case .keyDown:
                    swallow = owner.handle(.keyDown(code: code, command: event.flags.contains(.maskCommand), control: event.flags.contains(.maskControl)))
                case .keyUp: swallow = owner.handle(.keyUp(code: code))
                default: swallow = false
                }
                return swallow && type != .flagsChanged ? nil : Unmanaged.passUnretained(event)
            }
            guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                // Listen-only diagnoses permission differences, but cannot implement swallowed shortcuts.
                if let probe = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                    eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                    CFMachPortInvalidate(probe); Log.event("only listen-only event tap available")
                }
                lock.lock(); starting = false; lock.unlock(); return
            }
            let loop = CFRunLoopGetCurrent()
            lock.lock()
            guard generation == gen else { starting = false; lock.unlock(); CFMachPortInvalidate(created); return }
            tap = created; runLoop = loop; starting = false; lock.unlock()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            Log.event("event tap ready")
            CFRunLoopRun()
            CFMachPortInvalidate(created)
            lock.lock(); tap = nil; runLoop = nil; lock.unlock()
        }
        return false
    }
    func stop() {
        lock.lock(); generation += 1; let loop = runLoop; lock.unlock()
        if let loop { CFRunLoopStop(loop) }
    }
}
