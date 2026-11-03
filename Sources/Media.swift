import Foundation
import CoreAudio

func audioValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial, size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    return status == noErr ? value : nil
}
private func setAudio<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, value: T) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var value = value
    return withUnsafePointer(to: &value) { AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr
}
private func audioProcesses() -> [AudioProcess]? {
    // Public process objects include browser helper processes, unlike Now Playing alone.
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
    var processes: [AudioProcess] = []
    for id in ids {
        guard let pid = audioValue(id, kAudioProcessPropertyPID, initial: pid_t(0)),
              let input = audioValue(id, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)),
              let output = audioValue(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) else { return nil }
        let bundle: CFString? = audioValue(id, kAudioProcessPropertyBundleID, initial: Optional<CFString>.none) ?? nil
        processes.append(AudioProcess(pid: pid, bundleID: bundle as String?, runningOutput: output != 0, runningInput: input != 0))
    }
    return processes
}
final class Media {
    private let queue = DispatchQueue(label: "holler.media")
    private var generation = 0
    private var paused: MediaSnapshot?
    private var mutedDevice: AudioObjectID?
    private var oldVolume: Float32?
    private var missingLogged = false
    private func command(_ argument: String) -> Data? {
        guard let executable = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            if !missingLogged { Log.event("media-control missing"); missingLogged = true }; return nil
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [argument]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); Log.event("media-control timeout"); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
    private func snapshot() -> MediaSnapshot? {
        guard let data = command("get"), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let playing = json["playing"] as? Bool else { return nil }
        return MediaSnapshot(playing: playing, bundleID: json["bundleIdentifier"] as? String,
                             pid: (json["processIdentifier"] as? NSNumber)?.int32Value)
    }
    func start(pause: Bool, mute: Bool) {
        let checkAt = DispatchTime.now() + 0.35
        queue.async {
            self.generation += 1; let gen = self.generation
            if pause, let current = self.snapshot(), MediaPlan.shouldPause(current, enabled: pause), self.command("pause") != nil {
                self.paused = current; Log.event("paused Now Playing")
            }
            self.queue.asyncAfter(deadline: checkAt) {
                guard self.generation == gen, mute, let processes = audioProcesses(),
                      let device = audioValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)), device != 0 else { return }
                let muted = audioValue(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0))
                let volume = audioValue(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, initial: Float32(0))
                guard MediaPlan.shouldMute(processes: processes, ownPID: getpid(), paused: self.paused,
                    alreadyMuted: muted == 1 || volume == 0, enabled: mute) else { return }
                if muted != nil, setAudio(device, kAudioDevicePropertyMute, value: UInt32(1)) {
                    self.mutedDevice = device; self.oldVolume = nil
                } else if let volume, setAudio(device, kAudioDevicePropertyVolumeScalar, value: Float32(0)) {
                    self.mutedDevice = device; self.oldVolume = volume
                }
                if let device = self.mutedDevice {
                    // Remember across a crash so the next launch can give the sound back (see restoreAfterCrash).
                    UserDefaults.standard.set(["device": Int(device), "volume": Double(self.oldVolume ?? -1)], forKey: "mutedByHoller")
                    Log.event("muted residual output")
                }
            }
        }
    }
    // If Holler died while it had the sound muted, lift that mute on the next launch.
    func restoreAfterCrash() {
        guard let saved = UserDefaults.standard.dictionary(forKey: "mutedByHoller"),
              let device = (saved["device"] as? NSNumber)?.uint32Value else { return }
        queue.async {
            self.mutedDevice = AudioObjectID(device)
            let volume = (saved["volume"] as? NSNumber)?.floatValue ?? -1
            self.oldVolume = volume >= 0 ? Float32(volume) : nil
            Log.event("restoring mute left by a previous run")
        }
        finish()
    }
    /// `viaRunLoop`: deliver the completion as a main run-loop block instead of a main-queue dispatch. Quitting needs
    /// this: AppKit's terminate waits in a nested event loop, and if terminate was itself called from a main-queue
    /// block, the serial main queue can't run our completion until terminate returns - a deadlock.
    func finish(viaRunLoop: Bool = false, _ completion: @escaping () -> Void = {}) {
        queue.async {
            self.generation += 1
            // Restore the original device, even if the default changed. Preserve later user volume changes.
            var restored = true
            if let device = self.mutedDevice {
                if let volume = self.oldVolume {
                    if audioValue(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, initial: Float32(-1)) == 0 {
                        if !setAudio(device, kAudioDevicePropertyVolumeScalar, value: volume) { Log.event("volume restore failed"); restored = false }
                    }
                } else if !setAudio(device, kAudioDevicePropertyMute, value: UInt32(0)) { Log.event("unmute failed"); restored = false }
            }
            self.mutedDevice = nil; self.oldVolume = nil
            // A failed restore keeps the note, so the next launch (or the next dictation's finish) tries again.
            if restored { UserDefaults.standard.removeObject(forKey: "mutedByHoller") }
            if let paused = self.paused, let current = self.snapshot(), MediaPlan.shouldResume(paused: paused, current: current) {
                _ = self.command("play"); Log.event("resumed Now Playing")
            }
            self.paused = nil
            if viaRunLoop {
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, completion)
                CFRunLoopWakeUp(CFRunLoopGetMain())
            } else {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }
}
