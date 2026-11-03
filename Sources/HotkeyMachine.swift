import Foundation

// No timers or platform calls here: the tap supplies monotonic timestamps and ticks.
struct HotkeyMachine {
    enum State: Equatable { case idle, pending, holding, handsFree, finishing }
    enum Action: Equatable { case prepare, start, abort, finish, cancel, pasteLast }
    enum Event {
        case fn(down: Bool)
        case keyDown(code: UInt16, command: Bool, control: Bool)
        case keyUp(code: UInt16)
        case tick
        case completed
        case reset(fnDown: Bool)
    }
    struct Decision {
        var actions: [Action] = []
        var swallow = false
    }

    private(set) var state: State = .idle
    private(set) var fnDown = false
    private var pendingSince: TimeInterval = 0
    private var ignoredFn = false
    private var finishingFnChord = false
    private var swallowed: Set<UInt16> = []
    static let holdThreshold: TimeInterval = 0.25

    mutating func handle(_ event: Event, now: TimeInterval,
                         frontmostBundleID: String? = nil,
                         hasLastText: Bool = false,
                         excludedApps: Set<String> = []) -> Decision {
        var result = Decision()
        switch event {
        case .fn(let down):
            // Only keyCode 63 flagsChanged is translated to this event by the adapter.
            // Repeated modifier notifications must not restart pending or finish twice.
            guard down != fnDown else { return result }
            fnDown = down
            if down {
                ignoredFn = frontmostBundleID.map { excludedApps.contains($0) } ?? false
                if ignoredFn { return result }
                switch state {
                case .idle:
                    state = .pending; pendingSince = now
                    result.actions = [.prepare]
                case .handsFree:
                    state = .finishing; finishingFnChord = true
                    result.actions = [.finish]
                default: break
                }
            } else {
                finishingFnChord = false
                if ignoredFn { ignoredFn = false; return result }
                switch state {
                case .pending: state = .idle; result.actions = [.abort]
                case .holding: state = .finishing; result.actions = [.finish]
                default: break
                }
            }
            // flagsChanged always passes, including Fn releases after a swallowed chord.
        case .keyDown(let code, let command, let control):
            if swallowed.contains(code) { result.swallow = true; return result }
            if code == 9 && command && control && hasLastText {
                if state == .pending { state = .idle; result.actions.append(.abort) }
                result.actions.append(.pasteLast)
                result.swallow = true
            } else if state == .pending {
                if code == 49 {
                    state = .handsFree; result.actions = [.start]; result.swallow = true
                } else {
                    state = .idle; result.actions = [.abort]
                }
            } else if (state == .holding || state == .handsFree) && code == 53 {
                state = .idle; result.actions = [.cancel]; result.swallow = true
            } else if state == .holding && fnDown && code == 49 {
                state = .handsFree; result.swallow = true
            } else if state == .finishing && finishingFnChord && code == 49 {
                // Finishing happens on Fn down; still consume the Space of Fn+Space.
                result.swallow = true
            }
            if result.swallow { swallowed.insert(code) }
        case .keyUp(let code):
            result.swallow = swallowed.remove(code) != nil
        case .tick:
            if state == .pending && now - pendingSince >= Self.holdThreshold {
                state = .holding; result.actions = [.start]
            }
        case .completed:
            state = .idle
            finishingFnChord = false
        case .reset(let down):
            state = .idle; fnDown = down; ignoredFn = false; finishingFnChord = false; swallowed.removeAll()
        }
        return result
    }
}
