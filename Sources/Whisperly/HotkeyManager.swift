import AppKit

/// Watches the Fn (Globe) key globally. Hold = start, release = stop.
/// Requires Accessibility permission (also needed for pasting).
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnDown = false

    private static let fnKeyCode: UInt16 = 63

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handle(event)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.fnKeyCode else { return }
        let isDown = event.modifierFlags.contains(.function)
        if isDown && !fnDown {
            fnDown = true
            onPress?()
        } else if !isDown && fnDown {
            fnDown = false
            onRelease?()
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    static func ensureAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
