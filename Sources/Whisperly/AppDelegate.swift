import AppKit
import ServiceManagement

/// Thread-safe "first caller wins" flag, used by the transcription timeout.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotkey = HotkeyManager()
    private let overlay = OverlayPanel()

    private var history: [String] = []
    private var modelReady = false
    private var busy = false

    private var selectedModel: String {
        get { UserDefaults.standard.string(forKey: "model") ?? Transcriber.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "model") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        enableLoginItemOnce()
        setupStatusItem()

        let axTrusted = HotkeyManager.ensureAccessibilityPermission()
        if !axTrusted {
            setStatus("Grant Accessibility, then relaunch", symbol: "exclamationmark.triangle")
        }

        AudioRecorder.requestPermission { granted in
            if !granted {
                self.setStatus("Microphone access denied", symbol: "mic.slash")
            }
        }

        recorder.onLevel = { [weak self] rms in
            // Perceptual-ish scaling so quiet speech still moves the bars.
            let level = CGFloat(min(1.0, pow(Double(rms) * 14.0, 0.55)))
            self?.overlay.pushLevel(level)
        }

        hotkey.onPress = { [weak self] in self?.startDictation() }
        hotkey.onRelease = { [weak self] in self?.finishDictation() }
        hotkey.start()

        loadModel(selectedModel)
    }

    /// Turns on "Start at Login" the first time the app runs from a given
    /// location (e.g. after moving it into /Applications), re-pointing the
    /// login item at this copy. Unticking it in the menu later is respected.
    private func enableLoginItemOnce() {
        let key = "loginItemPath"
        let path = Bundle.main.bundlePath
        let stored = UserDefaults.standard.string(forKey: key)
        guard stored != path else { return }
        if stored == nil || SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
        }
        if SMAppService.mainApp.status == .enabled {
            UserDefaults.standard.set(path, forKey: key)
        }
    }

    /// Double-clicking the app in Finder while it's running lands here —
    /// there's no window, so show a status popup for feedback.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Whisperly is running"
        alert.informativeText = """
            Status: \(statusText)

            Hold the Fn (🌐) key anywhere, speak, release — \
            the text pastes where your cursor is. \
            The mic icon in the menu bar has history and settings.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return false
    }

    // MARK: - Model

    private func loadModel(_ model: String) {
        modelReady = false
        setStatus("Loading model…", symbol: "arrow.down.circle")
        Task {
            do {
                try await transcriber.load(model: model)
                self.modelReady = true
                self.setStatus("Ready — hold Fn to dictate", symbol: "mic")
            } catch {
                self.setStatus("Model failed: \(error.localizedDescription)", symbol: "xmark.circle")
            }
        }
    }

    // MARK: - Dictation flow

    private func startDictation() {
        guard modelReady, !busy, !recorder.isRecording else { return }
        do {
            try recorder.start()
            overlay.showRecording()
            setStatus("Listening…", symbol: "mic.fill")
        } catch {
            overlay.hide()
            setStatus("Mic error: \(error.localizedDescription)", symbol: "mic.slash")
        }
    }

    private func finishDictation() {
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        // Pill goes away the moment Fn is released.
        overlay.hide()
        guard samples.count > 8000 else {
            setStatus("Ready — hold Fn to dictate", symbol: "mic")
            return
        }

        busy = true
        setStatus("Transcribing…", symbol: "waveform")

        Task {
            defer { self.busy = false }
            do {
                let transcriber = self.transcriber
                let text = try await Self.withTimeout(seconds: 45) {
                    try await transcriber.transcribe(samples: samples)
                }
                if !text.isEmpty {
                    self.addToHistory(text)
                    if AXIsProcessTrusted() {
                        Paster.paste(text)
                        self.setStatus("Ready — hold Fn to dictate", symbol: "mic")
                    } else {
                        // Can't synthesize Cmd+V without Accessibility —
                        // leave the text on the clipboard instead.
                        Paster.copyOnly(text)
                        self.setStatus("Copied — press ⌘V (grant Accessibility for auto-paste)",
                                       symbol: "exclamationmark.triangle")
                        _ = HotkeyManager.ensureAccessibilityPermission()
                    }
                } else {
                    self.setStatus("Ready — hold Fn to dictate", symbol: "mic")
                }
            } catch {
                self.setStatus("Transcribe failed: \(error.localizedDescription)", symbol: "xmark.circle")
            }
        }
    }

    /// Gives up waiting after `seconds` so the overlay can never hang forever.
    nonisolated private static func withTimeout<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Unstructured on purpose: a task group would still wait for a hung
        // model call before returning. Whichever side finishes first wins.
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { cont in
            Task {
                do {
                    let value = try await work()
                    if once.claim() { cont.resume(returning: value) }
                } catch {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    cont.resume(throwing: NSError(
                        domain: "Whisperly", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "took too long — try again"]))
                }
            }
        }
    }

    private func addToHistory(_ text: String) {
        history.insert(text, at: 0)
        if history.count > 10 { history.removeLast() }
        rebuildMenu()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic",
                                           accessibilityDescription: "Whisperly")
        rebuildMenu()
    }

    private var statusText = "Starting…"

    private func setStatus(_ text: String, symbol: String) {
        statusText = text
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: text)
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if history.isEmpty {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (i, text) in history.enumerated() {
                let title = text.count > 60 ? String(text.prefix(60)) + "…" : text
                let item = NSMenuItem(title: title,
                                      action: #selector(copyHistoryItem(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let modelMenu = NSMenu()
        for model in Transcriber.availableModels {
            let name = model.replacingOccurrences(of: "openai_whisper-", with: "")
            let item = NSMenuItem(title: name,
                                  action: #selector(pickModel(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = model
            item.state = (model == selectedModel) ? .on : .off
            modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let login = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLogin(_:)),
                               keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let restart = NSMenuItem(title: "Restart Whisperly",
                                 action: #selector(restartApp),
                                 keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)
        let quit = NSMenuItem(title: "Quit Whisperly",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard sender.tag < history.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(history[sender.tag], forType: .string)
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String, model != selectedModel else { return }
        selectedModel = model
        loadModel(model)
    }

    @objc private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            setStatus("Login item failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
        rebuildMenu()
    }
}
