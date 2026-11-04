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

// Fn released sooner = tap; held longer = clipboard ghost. Raise it if slow taps open the ghost instead of the prompt.
let holdTime = 0.2

// MARK: - Pure logic (checked by --selftest)

/// Text for the hold-Fn overlay: capped so a huge clipboard can't fill the screen.
func ghostPreview(_ s: String?, maxLines: Int = 30, maxCols: Int = 200) -> String {
    guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "No text on clipboard" }
    let lines = s.components(separatedBy: "\n")
    let shown = lines.prefix(maxLines).map { String($0.prefix(maxCols)) }.joined(separator: "\n")
    return lines.count > maxLines ? shown + "\n… \(lines.count - maxLines) more lines" : shown
}

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

/// Menu line from `claude auth status --json`.
func accountLabel(_ d: [String: Any]?) -> String {
    guard let d else { return "Claude: unknown (is Claude Code installed?)" }
    guard d["loggedIn"] as? Bool == true else { return "Claude: not logged in (run claude auth login)" }
    let plan = (d["subscriptionType"] as? String).map { " · " + $0.capitalized } ?? ""
    return "Claude: " + (d["email"] as? String ?? "logged in") + plan
}

struct TapDetector {
    var downAt: Double?
    /// True when Fn was pressed and released quickly with no other key in between.
    mutating func fn(down: Bool, at t: Double) -> Bool {
        if down { downAt = t; return false }
        defer { downAt = nil }
        guard let d = downAt else { return false }
        return t - d < holdTime
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

final class GhostView: NSView {
    override func draw(_ r: NSRect) {
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let info = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    let projectItem = NSMenuItem(title: "VS Code: …", action: nil, keyEquivalent: "")
    let accountItem = NSMenuItem(title: "Claude: …", action: nil, keyEquivalent: "")
    var modelItems: [NSMenuItem] = []
    // Aliases: Claude Code resolves them to the newest Opus / Sonnet, so this never goes stale.
    var model: String { UserDefaults.standard.string(forKey: "model") ?? "opus" }
    let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 24),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let field = NSTextField()
    let ghost = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let ghostLabel = NSTextField(labelWithString: "")
    var ghostTimer: DispatchWorkItem?
    var ghostWatch: Timer?
    var tap = TapDetector()
    var lastTap = 0.0
    var task: Process?
    var revert: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        for item in [info, projectItem, accountItem] { item.isEnabled = false }
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(projectItem)
        menu.addItem(accountItem)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (alias, name) in [("opus", "Opus (latest)"), ("sonnet", "Sonnet (latest)")] {
            let item = NSMenuItem(title: name, action: #selector(pickModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = alias
            menu.addItem(item)
            modelItems.append(item)
        }
        menu.addItem(.separator())
        menu.delegate = self
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

        // Hold-Fn clipboard ghost: faint, click-through, never takes focus.
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = false
        ghost.animationBehavior = .none // appear/disappear instantly, no system fade
        ghost.alphaValue = 0.6
        ghost.ignoresMouseEvents = true
        ghost.level = .statusBar
        ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ghost.contentView = GhostView()
        ghostLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        ghostLabel.textColor = .white
        ghost.contentView!.addSubview(ghostLabel)

        // Watching the Fn key system-wide needs Accessibility permission.
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            info.title = "Grant Accessibility in System Settings, then relaunch"
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flags($0) }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flags($0); return $0 }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in self?.otherKey() }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in self?.otherKey(); return $0 }
    }

    func flags(_ e: NSEvent) {
        guard e.keyCode == 63 else { otherKey(); return } // 63 = Fn / Globe
        let down = e.modifierFlags.contains(.function)
        if down { scheduleGhost() } else { hideGhost() }
        if tap.fn(down: down, at: e.timestamp) { onTap(at: e.timestamp) }
    }

    func otherKey() { // Fn+arrow etc. is a shortcut, not a tap or a hold
        tap.otherKey()
        hideGhost()
    }

    // MARK: Ghost

    func scheduleGhost() {
        ghostTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.showGhost() }
        ghostTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + holdTime, execute: w)
    }

    func showGhost() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let pad: CGFloat = 16
        // As many lines as fit in 90% of the screen; one line is kept for "… N more lines".
        let lineHeight = NSLayoutManager().defaultLineHeight(for: ghostLabel.font!)
        let maxLines = max(1, Int((area.height * 0.9 - pad * 2) / lineHeight) - 1)
        let pb = NSPasteboard.general // password managers tag copied secrets as concealed
        let secret = pb.types?.contains(.init("org.nspasteboard.ConcealedType")) == true
        ghostLabel.stringValue = secret ? "Hidden: password" : ghostPreview(pb.string(forType: .string), maxLines: maxLines)
        let fit = ghostLabel.fittingSize
        let w = min(fit.width, area.width * 0.9), h = min(fit.height, area.height * 0.9 - pad * 2)
        ghostLabel.frame = NSRect(x: pad, y: pad, width: w, height: h)
        ghost.setFrame(NSRect(x: area.midX - w / 2 - pad, y: area.midY - h / 2 - pad,
                              width: w + pad * 2, height: h + pad * 2), display: true)
        ghost.orderFrontRegardless()
        // Fn-up can be missed (secure input in password fields blocks key monitors), so poll the real key state.
        ghostWatch?.invalidate()
        ghostWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            if !NSEvent.modifierFlags.contains(.function) { self?.hideGhost() }
        }
    }

    func hideGhost() {
        ghostTimer?.cancel()
        ghostTimer = nil
        ghostWatch?.invalidate()
        ghostWatch = nil
        ghost.orderOut(nil)
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
                       "--setting-sources", "user", "--model", model,
                       "--tools", "Read,Grep,Glob", "--append-system-prompt", systemPrompt]
        p.currentDirectoryURL = dir
        p.standardInput = inp; p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return fail(error.localizedDescription) }
        task = p
        inp.fileHandleForWriting.write(Data(prompt.utf8)) // prompt via stdin, never via a shell string
        try? inp.fileHandleForWriting.close()
        revert?.cancel()
        setIcon("hourglass")
        info.title = "Working in \(dir.lastPathComponent) with \(model.capitalized)…"
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

    // MARK: Menu

    func menuWillOpen(_ m: NSMenu) {
        let dir = pickProject(windowTitle: vscodeWindowTitle(), recent: recentVSCodeFolders())
        projectItem.title = "VS Code: " + (dir?.lastPathComponent ?? "no project found")
        if #available(macOS 14.4, *) { projectItem.subtitle = dir.map { ($0.path as NSString).abbreviatingWithTildeInPath } }
        refreshAccount() // async: menu shows the last known account until this returns
        for item in modelItems { item.state = item.representedObject as? String == model ? .on : .off }
    }

    @objc func pickModel(_ item: NSMenuItem) {
        UserDefaults.standard.set(item.representedObject as? String, forKey: "model")
    }

    func refreshAccount() {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec claude auth status --json"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            DispatchQueue.main.async { self.accountItem.title = accountLabel(d) }
        }
        try? p.run()
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
    precondition(ghostPreview(nil) == "No text on clipboard" && ghostPreview("  \n") == "No text on clipboard")
    precondition(ghostPreview("a\nb") == "a\nb")
    precondition(ghostPreview("1\n2\n3\n4", maxLines: 2) == "1\n2\n… 2 more lines")
    precondition(ghostPreview("abcdef", maxCols: 3) == "abc")
    precondition(accountLabel(["loggedIn": true, "email": "a@b.c", "subscriptionType": "max"]) == "Claude: a@b.c · Max")
    precondition(accountLabel(["loggedIn": false]).hasPrefix("Claude: not logged in"))
    precondition(accountLabel(nil).hasPrefix("Claude: unknown"))
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
