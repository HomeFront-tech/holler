import AppKit
import AVFoundation
import Speech
import ServiceManagement
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeys = Hotkeys(), dictation = Dictation(), ghost = Ghost(), inserter = Inserter(), media = Media()
    private let updater = Updater()
    private var status: NSStatusItem!
    private var permissionWindow: NSWindow?
    private var permissionLabel: NSTextField?
    private var retry: Timer?
    private var target = CaretTarget(pid: 0)
    private var generation = 0
    private enum Phase { case idle, prepared, recording, finishing }
    private var phase = Phase.idle
    private var recording = false
    private var terminating = false
    private var termSource: DispatchSourceSignal?
    private let defaults = UserDefaults.standard
    private let seed = """
    # One word or phrase per line for names or jargon Holler should spell correctly.
    # Lines starting with # are ignored.
    # Example: Acme Widgets

    """
    private var wordURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Holler/words.txt") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.enabled = true; Log.event("launch")
        // `kill`/`pkill` (build.sh, logout scripts) should quit politely: unmute, resume audio, restore clipboard.
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { NSApp.terminate(nil) }
        termSource?.resume()
        defaults.register(defaults: ["pauseAudio": true, "muteAudio": true, "sounds": true, "autoUpdate": true, "fnExcludedApps": [String]()])
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updater.isIdle = { [weak self] in
            guard let self else { return false }
            return self.phase == .idle && !self.inserter.busy && !self.terminating
        }
        updater.onChange = { [weak self] in self?.menu() }
        icon("mic"); menu()
        updater.start()
        dictation.words = { [weak self] in self?.words() ?? [] }
        dictation.onText = { [weak self] in self?.ghost.update($0) }
        dictation.onError = { [weak self] in self?.failedSession() }
        hotkeys.onAction = { [weak self] in self?.act($0) }
        _ = words()
        media.restoreAfterCrash()
        // Register as a login item once; the menu toggle can undo it.
        if !defaults.bool(forKey: "loginItemSetUp") {
            do { try SMAppService.mainApp.register(); defaults.set(true, forKey: "loginItemSetUp"); Log.event("registered login item") }
            catch { Log.event("login item registration failed") }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { permissions() }
        _ = hotkeys.start()
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            _ = self.hotkeys.start(); self.updatePermissionStatus()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
    }
    private func icon(_ name: String) {
        status.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Holler")
        status.button?.contentTintColor = name == "mic.fill" ? .systemRed : nil
    }
    private func sound(_ name: String) {
        guard defaults.bool(forKey: "sounds"), let sound = NSSound(named: name) else { return }
        sound.volume = 0.18; sound.play()
    }
    private func act(_ action: HotkeyMachine.Action) {
        guard !updater.installing, !terminating else { hotkeys.completed(); return }
        switch action {
        case .prepare:
            generation += 1; phase = .idle
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                  SFSpeechRecognizer.authorizationStatus() == .authorized else { hotkeys.completed(); permissions(); return }
            phase = .prepared
            dictation.prepare()
        case .start:
            guard phase == .prepared else { return }
            phase = .recording
            recording = true; target = Caret.capture(); ghost.show(at: target); icon("mic.fill")
            sound("Tink"); media.start(pause: defaults.bool(forKey: "pauseAudio"), mute: defaults.bool(forKey: "muteAudio"))
            dictation.start(); Log.event("recording started")
        case .abort: phase = .idle; dictation.cancel()
        case .cancel:
            // The tap also sends cancel when macOS re-enables it; with nothing running that must stay silent.
            guard phase != .idle else { return }
            phase = .idle
            generation += 1; let gen = generation
            dictation.cancel(); inserter.cancel(); ghost.hide(fade: true); recording = false; icon("mic")
            media.finish { if self.generation == gen { self.sound("Pop") } }
            Log.event("recording cancelled")
        case .finish:
            guard phase == .recording else { return }
            phase = .finishing
            let gen = generation
            recording = false; icon("waveform")
            dictation.finish { [weak self] text in
                guard let self, self.generation == gen else { return }
                if text.isEmpty { self.ghost.hide(); self.finishUI(gen); return }
                self.inserter.remember(text); self.hotkeys.setLastExists(true)
                self.inserter.paste(text, target: self.target) { success in
                    guard self.generation == gen else { return }
                    if success { self.ghost.hide() } else { self.ghost.failed(at: self.target) }
                    self.finishUI(gen)
                }
            }
        case .pasteLast:
            // A concurrent paste could overwrite an in-flight clipboard promise; keep one insertion at a time.
            guard !inserter.busy, !inserter.lastText.isEmpty else { return }
            let current = Caret.capture()
            inserter.paste(inserter.lastText, target: current) { success in if !success { self.ghost.failed(at: current) } }
        }
    }
    private func finishUI(_ gen: Int) {
        // Free Fn straight away; the media queue is serial, so a quick next dictation's pause still runs after
        // this resume. The stop click waits until any mute is lifted so it can be heard.
        phase = .idle; icon("mic"); hotkeys.completed()
        media.finish { if self.generation == gen { self.sound("Pop") } }
    }
    private func failedSession() {
        phase = .idle
        generation += 1; let gen = generation
        recording = false; ghost.hide(); icon("mic"); hotkeys.completed()
        media.finish { if self.generation == gen { self.status.button?.toolTip = "Microphone or offline dictation unavailable. Check Permissions and installed Dictation assets." } }
    }
    @objc private func sleeping() {
        phase = .idle
        generation += 1; dictation.cancel(); inserter.cancel(); ghost.hide(); hotkeys.completed(); recording = false; icon("mic"); media.finish()
    }
    private func menu() {
        let menu = NSMenu()
        if let title = updater.menuTitle {
            let update = NSMenuItem(title: title, action: #selector(installUpdate), keyEquivalent: "")
            update.target = self; update.isEnabled = !updater.installing; menu.addItem(update); menu.addItem(.separator())
        }
        let info = NSMenuItem(title: "Hold Fn to talk. Fn+Space hands-free. Esc cancels.", action: nil, keyEquivalent: "")
        info.isEnabled = false; menu.addItem(info); menu.addItem(.separator())
        for (title, key) in [("Pause audio while I talk", "pauseAudio"), ("Mute anything else that's playing", "muteAudio"), ("Sounds", "sounds"), ("Install updates automatically", "autoUpdate")] {
            let item = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = key; item.state = defaults.bool(forKey: key) ? .on : .off; menu.addItem(item)
        }
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        menu.addItem(.separator())
        for (title, action) in [("Check for Updates…", #selector(checkUpdates)), ("Edit word list…", #selector(editWords)), ("Permissions…", #selector(permissions)), ("Quit Holler", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        status.menu = menu
    }
    @objc private func toggle(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key); menu()
        if key == "autoUpdate" { updater.settingsChanged() }
    }
    @objc private func checkUpdates() { updater.check() }
    @objc private func installUpdate() { updater.activate() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { Log.event("login registration failed"); status.button?.toolTip = "Open at login failed. Install Holler in Applications first." }
        menu()
    }
    private func words() -> [String] {
        do {
            if !FileManager.default.fileExists(atPath: wordURL.path) {
                try FileManager.default.createDirectory(at: wordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try seed.write(to: wordURL, atomically: true, encoding: .utf8)
            }
            return try String(contentsOf: wordURL, encoding: .utf8).components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        } catch { Log.event("word list unavailable"); return [] }
    }
    @objc private func editWords() {
        _ = words()
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([wordURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: configuration)
    }
    @objc private func permissions() {
        if permissionWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 265), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Holler Permissions"; window.isReleasedWhenClosed = false
            let label = NSTextField(wrappingLabelWithString: "")
            label.frame = NSRect(x: 20, y: 145, width: 450, height: 100); window.contentView?.addSubview(label); permissionLabel = label
            for (index, name) in ["Microphone", "Speech Recognition", "Accessibility", "Input Monitoring"].enumerated() {
                let button = NSButton(title: "Open \(name) Settings", target: self, action: #selector(openPrivacy(_:)))
                button.tag = index; button.frame = NSRect(x: 20, y: 110 - index * 30, width: 450, height: 26); window.contentView?.addSubview(button)
            }
            permissionWindow = window; window.center()
        }
        updatePermissionStatus(); permissionWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func updatePermissionStatus() {
        permissionLabel?.stringValue = "Microphone: \(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "allowed" : "needed")\nSpeech Recognition: \(SFSpeechRecognizer.authorizationStatus() == .authorized ? "allowed" : "needed")\nAccessibility: \(AXIsProcessTrusted() ? "allowed" : "needed")\nInput Monitoring: \(CGPreflightListenEventAccess() ? "allowed" : "needed"). Holler retries automatically."
    }
    @objc private func openPrivacy(_ button: NSButton) {
        let panes = ["Privacy_Microphone", "Privacy_SpeechRecognition", "Privacy_Accessibility", "Privacy_ListenEvent"]
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + panes[button.tag]) { NSWorkspace.shared.open(url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true; updater.stop(); retry?.invalidate(); hotkeys.stop(); generation += 1
        dictation.cancel(); inserter.cancel(); ghost.hide()
        media.finish { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
