import AppKit
import Foundation

let args = CommandLine.arguments
if args.contains("--selftest") { exit(runSelfTests()) }
if let index = args.firstIndex(of: "--transcribe") {
    guard args.indices.contains(index + 1) else { fputs("Usage: Holler --transcribe FILE\n", stderr); exit(2) }
    // CLI modes never initialize AppDelegate, preferences, logs, permissions UI or microphone.
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
        fputs("Transcription failed: speech service timed out after 30 seconds\n", stderr); exit(1)
    }
    Task {
        do { print(try await transcribeFile(args[index + 1])); exit(0) }
        catch { fputs("Transcription failed: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if args.contains("--ghost-demo") {
        let ghost = Ghost()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let target = CaretTarget(pid: 0, caret: NSRect(x: screen.midX - 180, y: screen.midY, width: 0, height: 24),
                                 frame: NSRect(x: screen.midX - 200, y: screen.midY - 100, width: 420, height: 160))
        ghost.show(at: target); ghost.update("Testing Holler in a text field")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { ghost.show(at: target, forceBubble: true); ghost.update("Words appear here when no caret is available") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { ghost.hide(); app.terminate(nil) }
        app.run()
    } else {
        let delegate = AppDelegate(); app.delegate = delegate; app.run()
    }
}
