import Foundation

struct MediaSnapshot: Equatable {
    var playing: Bool
    var bundleID: String?
    var pid: Int32?
}

struct AudioProcess {
    var pid: Int32
    var bundleID: String?
    var runningOutput: Bool
    var runningInput: Bool
}

struct MediaPlan {
    static func shouldPause(_ current: MediaSnapshot?, enabled: Bool = true) -> Bool {
        enabled && current?.playing == true
    }

    static func shouldMute(processes: [AudioProcess], ownPID: Int32,
                           paused: MediaSnapshot?, alreadyMuted: Bool,
                           enabled: Bool = true) -> Bool {
        guard enabled && !alreadyMuted else { return false }
        let other = processes.filter { $0.pid != ownPID }
        // Input is intentionally checked across all processes: never mute a call.
        guard !other.contains(where: { $0.runningInput }) else { return false }
        return other.contains { process in
            guard process.runningOutput else { return false }
            if let pausedPID = paused?.pid, process.pid == pausedPID { return false }
            if let bundle = paused?.bundleID, !bundle.isEmpty, process.bundleID == bundle { return false }
            return true
        }
    }

    static func shouldResume(paused: MediaSnapshot?, current: MediaSnapshot?) -> Bool {
        guard let paused, paused.playing,
              let bundle = paused.bundleID, !bundle.isEmpty,
              let current, !current.playing, current.bundleID == bundle else { return false }
        // Do not restart a new instance of the same app when both PIDs are known.
        if let old = paused.pid, let now = current.pid, old != now { return false }
        return true
    }
}
