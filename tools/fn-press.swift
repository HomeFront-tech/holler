// Dev test tool: presses the Fn key by software, for end-to-end tests of Holler without anyone at the keyboard.
//   fn-press check        -> prints whether this process may post keyboard events (needs Accessibility)
//   fn-press hold SECS    -> Fn down, wait SECS, Fn up   (hold-to-talk)
//   fn-press tap          -> a quick Fn tap (< Holler's 250 ms threshold)
//   fn-press esc          -> Esc down/up
//   fn-press seq TOKENS   -> fn+ fn- space esc pastelast sleep:SECS, in order (e.g. Fn+Space hands-free)
import ApplicationServices
import CoreGraphics
import Foundation

func fn(_ down: Bool) {
    guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 63, keyDown: down) else { return }
    e.type = .flagsChanged
    e.flags = down ? .maskSecondaryFn : []
    e.post(tap: .cghidEventTap)
}
func key(_ code: CGKeyCode) {
    for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
}
let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "" {
case "check": print(AXIsProcessTrusted() ? "can post events" : "NOT trusted for Accessibility")
case "hold": fn(true); Thread.sleep(forTimeInterval: Double(args.dropFirst().first ?? "2") ?? 2); fn(false)
case "tap": fn(true); Thread.sleep(forTimeInterval: 0.08); fn(false)
case "esc": key(53)
case "seq":
    for t in args.dropFirst() {
        switch t {
        case "fn+": fn(true)
        case "fn-": fn(false)
        case "space": key(49)
        case "esc": key(53)
        case "pastelast":
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down)
                e?.flags = [.maskCommand, .maskControl]; e?.post(tap: .cghidEventTap)
            }
        default:
            if t.hasPrefix("sleep:"), let s = Double(t.dropFirst(6)) { Thread.sleep(forTimeInterval: s) }
        }
        Thread.sleep(forTimeInterval: 0.03)
    }
default: print("usage: fn-press check | hold SECS | tap | esc")
}
