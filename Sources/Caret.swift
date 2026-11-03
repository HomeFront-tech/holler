import AppKit
import ApplicationServices

struct CaretTarget {
    var pid: pid_t
    var element: AXUIElement?
    var caret: CGRect?
    var frame: CGRect?
    var value: String?
    var location: Int?
}
enum Caret {
    private static var enabledPIDs = Set<pid_t>()
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func range(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range, result: CFTypeRef?
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
    }
    static func cocoa(_ rect: CGRect) -> CGRect {
        // AX's origin is the primary display's top left; other displays may have negative coordinates.
        CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }
    static func capture() -> CaretTarget {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        if !enabledPIDs.contains(pid), let url = app?.bundleURL {
            let frameworks = url.appendingPathComponent("Contents/Frameworks")
            let electron = FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path)
            let chromium = electron || ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium", "company.thebrowser.Browser"].contains(app?.bundleIdentifier ?? "")
            // Chromium and Electron build their text-range tree only when asked. AXManualAccessibility asks without
            // the side effects of AXEnhancedUserInterface (which upsets window animations / window managers).
            if chromium { AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
            enabledPIDs.insert(pid)
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let focused = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return CaretTarget(pid: pid)
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        var target = CaretTarget(pid: pid, element: element)
        if let pos = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
           CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var p = CGPoint.zero, s = CGSize.zero
            if AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) { target.frame = cocoa(CGRect(origin: p, size: s)) }
        }
        if let selected = range(element) {
            target.location = selected.location
            if let rect = bounds(element, CFRange(location: selected.location, length: 0)), rect.height > 0, rect.width >= 0 {
                target.caret = cocoa(rect)
            } else if selected.location > 0, let rect = bounds(element, CFRange(location: selected.location - 1, length: 1)), rect.height > 0 {
                target.caret = cocoa(CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height))
            }
        }
        // Only the character before the caret matters (leading-space rule). Reading kAXValue would copy the whole
        // field, which in a terminal or long document can be megabytes, twice per dictation.
        if let loc = target.location, loc > 0 {
            var one = CFRange(location: loc - 1, length: 1), result: CFTypeRef?
            if let param = AXValueCreate(.cfRange, &one),
               AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &result) == .success,
               let prev = result as? String, !prev.isEmpty {
                target.value = prev; target.location = (prev as NSString).length
            }
        }
        return target
    }
    // Same app still in front. Element identity isn't compared: Chromium and others hand back a fresh AXUIElement
    // for the same field on every query, and a click into another field of the same app should still get the text.
    static func stillFocused(_ original: CaretTarget) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == original.pid
    }
}
