// ClaudeClip: menu bar app. Tap Fn, type a prompt blind, press Enter.
// Claude Code reads your current VS Code project and puts code on the clipboard.
// Double-tap Fn clears the clipboard.
import Cocoa
import ApplicationServices

let systemPrompt = """
You run headless behind a clipboard hotkey. The user is coding in this project. \
Read the codebase as needed (Read/Grep/Glob) so the code matches its existing style, imports and conventions. \
Your final reply is copied straight to the clipboard and pasted into the editor, so reply with ONLY the code: \
no explanation, no markdown fences, no preamble. If the answer spans several files, put a comment line with \
the file path before each file's code. If the request is unclear, make the most reasonable assumption and still reply with code only.
"""

// MARK: - Pure logic (checked by --selftest)

func stripFences(_ s: String) -> String {
    var lines = s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
    if lines.last?.hasPrefix("```") == true { lines.removeLast() }
    return lines.joined(separator: "\n")
}

/// VS Code titles look like "● App.tsx — my-app". Match a title part to a folder name, else newest folder.
func pickProject(windowTitle: String?, recent: [URL]) -> URL? {
    let parts = Set((windowTitle ?? "")
        .components(separatedBy: " — ").flatMap { $0.components(separatedBy: " - ") }
        .map { $0.trimmingCharacters(in: .whitespaces) })
    return recent.first { parts.contains($0.lastPathComponent) } ?? recent.first
}

struct TapDetector {
    var downAt: Double?
    /// True when Fn was pressed and released quickly with no other key in between.
    mutating func fn(down: Bool, at t: Double) -> Bool {
        if down { downAt = t; return false }
        defer { downAt = nil }
        guard let d = downAt else { return false }
        return t - d < 0.35
    }
    mutating func otherKey() { downAt = nil }
}

// MARK: - VS Code lookup

/// Folders VS Code has opened, newest first (from its per-workspace storage).
func recentVSCodeFolders() -> [URL] {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Code/User/workspaceStorage")
    guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
    return dirs.compactMap { d -> (Date, URL)? in
        guard let data = try? Data(contentsOf: d.appendingPathComponent("workspace.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["folder"] as? String, let u = URL(string: s), u.isFileURL,
              fm.fileExists(atPath: u.path) else { return nil }
        let m = (try? d.appendingPathComponent("state.vscdb")
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return (m, u)
    }.sorted { $0.0 > $1.0 }.map { $0.1 }
}

func vscodeWindowTitle() -> String? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCode").first
    else { return nil }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var win: CFTypeRef?, title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
          let w = win else { return nil }
    AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title)
    return title as? String
}

// MARK: - App

final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let info = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 24),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let field = NSTextField()
    var tap = TapDetector()
    var lastTap = 0.0
    var task: Process?
    var revert: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
        setIcon(idleIcon)

        // ponytail: invisible by design (alpha 0). Set to 1 to debug the prompt box.
        panel.alphaValue = 0
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        field.frame = panel.contentView!.bounds
        field.delegate = self
        panel.contentView!.addSubview(field)

        // Watching the Fn key system-wide needs Accessibility permission.
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            info.title = "Grant Accessibility in System Settings, then relaunch"
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flags($0) }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flags($0); return $0 }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in self?.tap.otherKey() }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in self?.tap.otherKey(); return $0 }
    }

    func flags(_ e: NSEvent) {
        guard e.keyCode == 63 else { tap.otherKey(); return } // 63 = Fn / Globe
        if tap.fn(down: e.modifierFlags.contains(.function), at: e.timestamp) { onTap(at: e.timestamp) }
    }

    func onTap(at t: Double) {
        if t - lastTap < 0.35 { // double tap: first tap opened the prompt, so close it and clear
            lastTap = 0
            hidePrompt()
            NSPasteboard.general.clearContents()
            NSSound(named: "Tink")?.play()
            flash("trash", "Clipboard cleared")
            return
        }
        lastTap = t
        panel.isVisible ? hidePrompt() : showPrompt()
    }

    // MARK: Prompt

    func showPrompt() {
        field.stringValue = ""
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        setIcon("keyboard")
    }

    func hidePrompt() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        field.stringValue = ""
        setIcon(idleIcon)
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let prompt = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            hidePrompt()
            if !prompt.isEmpty { run(prompt) }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { hidePrompt(); return true }
        return false
    }

    func windowDidResignKey(_ n: Notification) { hidePrompt() } // clicked elsewhere: don't trap keystrokes

    // MARK: Claude

    func run(_ prompt: String) {
        guard let dir = pickProject(windowTitle: vscodeWindowTitle(), recent: recentVSCodeFolders()) else {
            return fail("No VS Code project found")
        }
        task?.terminate() // ponytail: a new prompt replaces a running one
        let p = Process(), inp = Pipe(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell finds `claude` on your PATH; "$@" passes args with no shell parsing.
        // Read-only tools: Claude can look at the code but can't edit files or run commands.
        // User settings only: a cloned repo's .claude/settings.json hooks would otherwise run shell commands.
        p.arguments = ["-lc", "exec claude \"$@\"", "zsh", "-p", "--strict-mcp-config", "--no-session-persistence",
                       "--setting-sources", "user",
                       "--tools", "Read,Grep,Glob", "--append-system-prompt", systemPrompt]
        p.currentDirectoryURL = dir
        p.standardInput = inp; p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return fail(error.localizedDescription) }
        task = p
        inp.fileHandleForWriting.write(Data(prompt.utf8)) // prompt via stdin, never via a shell string
        try? inp.fileHandleForWriting.close()
        revert?.cancel()
        setIcon("hourglass")
        info.title = "Working in \(dir.lastPathComponent)…"
        DispatchQueue.global().async {
            // ponytail: stderr read after stdout; would stall only if claude wrote >64KB to stderr
            let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            DispatchQueue.main.async { self.done(p, o, e) }
        }
    }

    func done(_ p: Process, _ out: String, _ err: String) {
        guard task === p else { return } // replaced by a newer prompt
        task = nil
        let code = stripFences(out)
        guard p.terminationStatus == 0, !code.isEmpty else { return fail(err.isEmpty ? out : err) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        NSSound(named: "Glass")?.play()
        flash("checkmark.circle", "Copied \(code.components(separatedBy: "\n").count) lines")
    }

    func fail(_ msg: String) {
        task = nil
        NSSound(named: "Basso")?.play()
        revert?.cancel()
        setIcon("exclamationmark.triangle")
        info.title = "Error: " + msg.trimmingCharacters(in: .whitespacesAndNewlines).prefix(150)
    }

    // MARK: Icon

    var idleIcon: String { task == nil ? "sparkles" : "hourglass" }

    func setIcon(_ name: String) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "ClaudeClip")
        img?.isTemplate = true
        status.button?.image = img
    }

    func flash(_ icon: String, _ text: String) {
        setIcon(icon)
        info.title = text
        revert?.cancel()
        let w = DispatchWorkItem { [weak self] in self.map { $0.setIcon($0.idleIcon) } }
        revert = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }
}

// MARK: - Entry

if CommandLine.arguments.contains("--selftest") {
    precondition(stripFences("```tsx\nconst a = 1\n```") == "const a = 1")
    precondition(stripFences("const a = 1\n") == "const a = 1")
    let api = URL(fileURLWithPath: "/p/api"), app = URL(fileURLWithPath: "/p/my-app")
    precondition(pickProject(windowTitle: "● App.tsx — my-app", recent: [api, app]) == app)
    precondition(pickProject(windowTitle: "App.tsx — my-app-api", recent: [api, app]) == api) // no exact match → newest
    precondition(pickProject(windowTitle: nil, recent: []) == nil)
    var t = TapDetector()
    precondition(!t.fn(down: true, at: 0) && t.fn(down: false, at: 0.1))   // quick tap
    precondition(!t.fn(down: true, at: 1) && !t.fn(down: false, at: 1.6))  // held too long
    _ = t.fn(down: true, at: 2); t.otherKey()
    precondition(!t.fn(down: false, at: 2.1))                               // Fn + another key
    print("selftest ok")
    exit(0)
}

let delegate = App()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
