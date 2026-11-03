import Foundation

// Deliberately accept event labels only; callers never pass transcript or AX contents.
enum Log {
    static var enabled = false
    private static let queue = DispatchQueue(label: "holler.log")
    static func event(_ name: String) {
        guard enabled else { return }
        queue.async {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Holler")
            let file = dir.appendingPathComponent("holler.log")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   (attrs[.size] as? NSNumber)?.intValue ?? 0 > 950_000 {
                    let old = dir.appendingPathComponent("holler.log.1")
                    if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.removeItem(at: old) }
                    try FileManager.default.moveItem(at: file, to: old)
                }
                let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(name)\n".utf8)
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            } catch { /* Logging must never interrupt dictation. */ }
        }
    }
}
