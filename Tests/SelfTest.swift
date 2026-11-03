import Foundation

func runSelfTests() -> Int32 {
    var passed = 0
    var failed = 0
    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() { passed += 1; print("PASS \(name)") }
        else { failed += 1; print("FAIL \(name)") }
    }
    typealias M = HotkeyMachine
    func down(_ code: UInt16, command: Bool = false, control: Bool = false) -> M.Event {
        .keyDown(code: code, command: command, control: control)
    }

    var m = M()
    var d = m.handle(.fn(down: true), now: 0)
    check("Fn down prepares without swallowing flags", d.actions == [.prepare] && !d.swallow && m.state == .pending)
    check("hold below threshold does not start", m.handle(.tick, now: 0.249).actions.isEmpty)
    check("hold at 250ms starts", m.handle(.tick, now: 0.25).actions == [.start] && m.state == .holding)
    check("hold ticks start only once", m.handle(.tick, now: 0.3).actions.isEmpty)
    d = m.handle(.fn(down: false), now: 0.6)
    check("hold release finishes and passes flags", d.actions == [.finish] && !d.swallow && m.state == .finishing)
    _ = m.handle(.completed, now: 0.7)
    check("completion returns idle", m.state == .idle)

    // Tap recovery: a Fn release lost while macOS had the tap disabled must not eat the next hold.
    m = M(); _ = m.handle(.fn(down: true), now: 0); _ = m.handle(.tick, now: 0.3)
    _ = m.handle(down(49), now: 0.35)          // Space swallowed (hands-free)
    _ = m.handle(.reset(fnDown: false), now: 5) // Fn was released while the tap was off
    check("reset returns idle", m.state == .idle)
    check("reset forgets swallowed keys", !m.handle(.keyUp(code: 49), now: 5.1).swallow)
    check("Fn works right after reset", m.handle(.fn(down: true), now: 6).actions == [.prepare])

    m = M(); _ = m.handle(.fn(down: true), now: 1)
    d = m.handle(.fn(down: false), now: 1.1)
    check("quick Fn tap aborts", d.actions == [.abort] && !d.swallow && m.state == .idle)
    check("aborted pending tick cannot start", m.handle(.tick, now: 1.3).actions.isEmpty)

    m = M(); _ = m.handle(.fn(down: true), now: 0)
    d = m.handle(down(123), now: 0.1)
    check("Fn+Left aborts and passes arrow", d.actions == [.abort] && !d.swallow && m.state == .idle)
    check("arrow up passes", !m.handle(.keyUp(code: 123), now: 0.15).swallow)
    check("aborted Fn release passes", !m.handle(.fn(down: false), now: 0.2).swallow)

    m = M(); _ = m.handle(.fn(down: true), now: 0)
    d = m.handle(down(49), now: 0.1)
    check("Fn+Space starts hands-free and swallows Space down", d.actions == [.start] && d.swallow && m.state == .handsFree)
    d = m.handle(down(49), now: 0.12)
    check("Space repeat swallowed without duplicate start", d.swallow && d.actions.isEmpty)
    check("Space up swallowed", m.handle(.keyUp(code: 49), now: 0.15).swallow)
    d = m.handle(.fn(down: false), now: 0.2)
    check("hands-free survives Fn up and passes flags", m.state == .handsFree && d.actions.isEmpty && !d.swallow)
    d = m.handle(.fn(down: true), now: 0.4)
    check("next Fn down finishes hands-free and passes flags", d.actions == [.finish] && !d.swallow && m.state == .finishing)
    check("finishing Fn+Space consumes Space", m.handle(down(49), now: 0.41).swallow)
    check("finishing Space keyUp swallowed", m.handle(.keyUp(code: 49), now: 0.42).swallow)
    d = m.handle(.fn(down: false), now: 0.5)
    check("matching Fn up does not finish twice", d.actions.isEmpty && !d.swallow)

    m = M(); _ = m.handle(.fn(down: true), now: 0); _ = m.handle(.tick, now: 0.3)
    d = m.handle(down(49), now: 0.4)
    check("held Fn+Space switches to hands-free without restarting", d.actions.isEmpty && d.swallow && m.state == .handsFree)
    _ = m.handle(.keyUp(code: 49), now: 0.45)
    d = m.handle(down(53), now: 0.5)
    check("Esc cancels hands-free and swallows down", d.actions == [.cancel] && d.swallow && m.state == .idle)
    check("Esc up still swallowed after state changes", m.handle(.keyUp(code: 53), now: 0.55).swallow)

    m = M(); _ = m.handle(.fn(down: true), now: 0); _ = m.handle(.tick, now: 0.3)
    d = m.handle(down(53), now: 0.4)
    check("Esc cancels holding", d.actions == [.cancel] && d.swallow && m.state == .idle)
    _ = m.handle(.keyUp(code: 53), now: 0.45)
    check("Fn up after cancel does nothing", m.handle(.fn(down: false), now: 0.5).actions.isEmpty)
    check("idle Esc passes", !m.handle(down(53), now: 0.6).swallow)
    check("idle Space passes", !m.handle(down(49), now: 0.7).swallow)

    m = M()
    d = m.handle(down(9, command: true, control: true), now: 0)
    check("paste-last without text passes", d.actions.isEmpty && !d.swallow)
    d = m.handle(down(9, command: true, control: true), now: 0.1, hasLastText: true)
    check("paste-last with text swallowed and dispatched", d.actions == [.pasteLast] && d.swallow)
    check("paste-last keyUp swallowed", m.handle(.keyUp(code: 9), now: 0.2).swallow)
    d = m.handle(down(9, command: true), now: 0.3, hasLastText: true)
    check("synthetic ordinary Cmd+V ignored", d.actions.isEmpty && !d.swallow)

    m = M()
    d = m.handle(.fn(down: true), now: 0, frontmostBundleID: "com.example.keeps-fn", excludedApps: ["com.example.keeps-fn"])
    check("Excluded app Fn ignored entirely", d.actions.isEmpty && !d.swallow && m.state == .idle)
    check("Excluded app hold has no timer action", m.handle(.tick, now: 1).actions.isEmpty)
    check("Excluded app Space passes", !m.handle(down(49), now: 1.1).swallow)
    d = m.handle(.fn(down: false), now: 1.2)
    check("Excluded app Fn up passes", d.actions.isEmpty && !d.swallow)
    d = m.handle(.fn(down: true), now: 2, frontmostBundleID: "com.apple.TextEdit")
    check("next ordinary app Fn works", d.actions == [.prepare])
    d = m.handle(.fn(down: true), now: 2.1)
    check("duplicate Fn down does not reset threshold", d.actions.isEmpty && m.handle(.tick, now: 2.25).actions == [.start])

    m = M()
    check("empty excluded list allows any app", m.handle(.fn(down: true), now: 0,
        frontmostBundleID: "com.example.keeps-fn", excludedApps: []).actions == [.prepare])

    var t = Transcript()
    check("empty transcript", t.text == "")
    t.receive("  Testing  ", isFinal: false)
    check("volatile text trimmed", t.text == "Testing")
    t.receive(" Testing Holler ", isFinal: false)
    check("volatile revision replaces previous", t.text == "Testing Holler")
    t.receive("Testing Holler", isFinal: true)
    check("final replaces volatile without duplication", t.text == "Testing Holler")
    t.receive(" at the garden ", isFinal: false)
    check("final and volatile join with single space", t.text == "Testing Holler at the garden")
    t.receive("at the garden today.", isFinal: true)
    check("ordered finals", t.text == "Testing Holler at the garden today.")
    t.receive(" \n", isFinal: false)
    check("empty volatile adds no trailing space", t.text == "Testing Holler at the garden today.")

    check("spacing at start", Spacing.prefix(value: "abc", caretUTF16: 0) == "")
    check("spacing after space", Spacing.prefix(value: "abc ", caretUTF16: 4) == "")
    check("spacing after newline", Spacing.prefix(value: "abc\n", caretUTF16: 4) == "")
    check("spacing after letter", Spacing.prefix(value: "abc", caretUTF16: 3) == " ")
    check("spacing after opening bracket", Spacing.prefix(value: "(", caretUTF16: 1) == "")
    check("spacing with unavailable AX value", Spacing.prefix(value: nil, caretUTF16: 2) == "")
    check("spacing with invalid AX offset", Spacing.prefix(value: "x", caretUTF16: 5) == "")
    check("spacing uses UTF16 for emoji", Spacing.prefix(value: "🙂 hi", caretUTF16: 2) == " ")

    let playing = MediaSnapshot(playing: true, bundleID: "player", pid: 101)
    let paused = MediaSnapshot(playing: false, bundleID: "player", pid: 101)
    check("quiet room no pause", !MediaPlan.shouldPause(nil) && !MediaPlan.shouldPause(paused))
    check("quiet room no resume", !MediaPlan.shouldResume(paused: nil, current: paused))
    check("playing media pauses", MediaPlan.shouldPause(playing))
    check("paused media resumes", MediaPlan.shouldResume(paused: playing, current: paused))
    check("pause toggle respected", !MediaPlan.shouldPause(playing, enabled: false))
    check("changed Now Playing app does not resume", !MediaPlan.shouldResume(paused: playing, current: MediaSnapshot(playing: false, bundleID: "different", pid: 202)))
    check("already resumed app not restarted", !MediaPlan.shouldResume(paused: playing, current: playing))
    check("unknown player identity not resumed", !MediaPlan.shouldResume(paused: MediaSnapshot(playing: true, bundleID: nil, pid: nil), current: MediaSnapshot(playing: false, bundleID: nil, pid: nil)))
    check("restarted player instance not resumed", !MediaPlan.shouldResume(paused: playing, current: MediaSnapshot(playing: false, bundleID: "player", pid: 303)))
    let game = AudioProcess(pid: 200, bundleID: "game", runningOutput: true, runningInput: false)
    let own = AudioProcess(pid: 1, bundleID: "com.github.homefront-tech.holler", runningOutput: true, runningInput: true)
    let call = AudioProcess(pid: 300, bundleID: "call", runningOutput: false, runningInput: true)
    let music = AudioProcess(pid: 101, bundleID: "player", runningOutput: true, runningInput: false)
    check("other output muted", MediaPlan.shouldMute(processes: [game, own], ownPID: 1, paused: nil, alreadyMuted: false))
    check("call input prevents mute", !MediaPlan.shouldMute(processes: [game, call], ownPID: 1, paused: nil, alreadyMuted: false))
    check("already muted left alone", !MediaPlan.shouldMute(processes: [game], ownPID: 1, paused: nil, alreadyMuted: true))
    check("paused player output excluded", !MediaPlan.shouldMute(processes: [music, own], ownPID: 1, paused: playing, alreadyMuted: false))
    check("mute toggle respected", !MediaPlan.shouldMute(processes: [game], ownPID: 1, paused: nil, alreadyMuted: false, enabled: false))
    check("version compares numerically", ReleaseVersion("v1.10.0")! > ReleaseVersion("v1.9.3")!)
    check("version accepts optional v", ReleaseVersion("1.0.0") == ReleaseVersion("v1.0.0"))
    check("version compares major first", ReleaseVersion("2.0.0")! > ReleaseVersion("1.99.99")!)
    check("version compares patch", ReleaseVersion("1.0.1")! > ReleaseVersion("1.0.0")!)
    check("junk versions ignored", ["", "latest", "1.2", "1.2.3.4", "v.1.2", "-1.0.0", "1. 2.3", "1.2.3\n"].allSatisfy { ReleaseVersion($0) == nil })
    check("prerelease and metadata tags ignored", ["v1.1.0-beta", "1.0.0+build", "V1.0.0"].allSatisfy { ReleaseVersion($0) == nil })
    check("overflowing versions ignored", ReleaseVersion("999999999999999999999999.0.0") == nil)
    let assetURL = URL(string: "https://example.com/release.zip")!
    let fallbackAsset = ReleaseAsset(name: "other.zip", browser_download_url: assetURL)
    let exactAsset = ReleaseAsset(name: "Holler-1.10.0.zip", browser_download_url: assetURL)
    let nonZip = ReleaseAsset(name: "notes.txt", browser_download_url: assetURL)
    let version = ReleaseVersion("1.10.0")!
    check("named update asset preferred", UpdatePlan.asset(for: version, in: [fallbackAsset, exactAsset]) == exactAsset)
    check("first zip is fallback", UpdatePlan.asset(for: version, in: [nonZip, fallbackAsset]) == fallbackAsset)
    check("missing zip yields no asset", UpdatePlan.asset(for: version, in: [nonZip]) == nil)
    check("empty assets yield no asset", UpdatePlan.asset(for: version, in: []) == nil)
    let running = ReleaseVersion("1.0.0")!
    func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(tag_name: tag, assets: [], draft: draft, prerelease: prerelease)
    }
    check("new release offered", UpdatePlan.newerVersion(release("v1.10.0"), than: running) == version)
    check("same release ignored", UpdatePlan.newerVersion(release("v1.0.0"), than: running) == nil)
    check("older release ignored", UpdatePlan.newerVersion(release("v0.9.0"), than: running) == nil)
    check("draft release ignored", UpdatePlan.newerVersion(release("v2.0.0", draft: true), than: running) == nil)
    check("prerelease flag ignored", UpdatePlan.newerVersion(release("v2.0.0", prerelease: true), than: running) == nil)
    check("prerelease tag ignored", UpdatePlan.newerVersion(release("v2.0.0-beta"), than: running) == nil)
    print("\(passed) passed, \(failed) failed")
    return failed == 0 ? 0 : 1
}
