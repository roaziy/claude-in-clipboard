# ClaudeClip

Tap **Fn**, type a prompt (invisibly), press **Enter**. Claude Code reads the project open in VS Code and puts the code on your clipboard. Double-tap **Fn** to clear the clipboard.

It lives in the menu bar: no Dock icon, no window.

```
Fn  →  type "add a dark mode toggle to settings"  →  Enter  →  ⌘V
```

## Requirements

- macOS 13 or later, Apple Silicon
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged in (`claude` works in your terminal)
- VS Code

## Install

**From a release:** download `ClaudeClip.zip` from [Releases](../../releases), unzip it and move `ClaudeClip.app` to `/Applications`. The app isn't notarized, so clear the download flag once:

```sh
xattr -dr com.apple.quarantine /Applications/ClaudeClip.app
```

**From source** (needs Xcode Command Line Tools: `xcode-select --install`):

```sh
git clone https://github.com/roaziy/claude-in-clipboard
cd claude-in-clipboard
./build.sh
open build/ClaudeClip.app
```

## Setup (once)

1. **Accessibility:** System Settings → Privacy & Security → Accessibility → turn on **ClaudeClip**, then quit and reopen it. This lets it see the Fn key and read the VS Code window title.
2. **Files:** the first time you prompt in a project inside Documents, Desktop or Downloads, macOS asks to let ClaudeClip access that folder. Click **Allow**. If you see `EPERM` in the menu, turn it on in System Settings → Privacy & Security → Files & Folders → ClaudeClip.
3. **Fn key:** System Settings → Keyboard → **Press 🌐 key to** → **Do Nothing**. Otherwise Fn also opens the emoji picker.
4. **Optional:** System Settings → General → Login Items → add ClaudeClip.

## Usage

| Do | Result |
| --- | --- |
| Tap Fn | Opens the invisible prompt |
| Type, then Enter | Sends it to Claude |
| Esc, tap Fn again, or click elsewhere | Cancels |
| Double-tap Fn | Clears the clipboard |
| Hold Fn (over 0.2 s) | Shows a faint preview of the clipboard (nothing is pasted). Release to hide it. Passwords copied from a password manager show as "Hidden" |

The menu bar icon shows what's happening:

| Icon | Meaning |
| --- | --- |
| ✨ | Ready |
| ⌨️ | Prompt open, typing |
| ⌛ | Claude is working (usually 5–20 s) |
| ✓ + sound | Code is on the clipboard |
| ⚠️ + sound | Failed. Click the icon to read the error |

Pick the model from the menu: **Opus (latest)** (default) or **Sonnet (latest)**. Both always use the newest version.

If an answer spans several files, they come as one block with a `// path/to/file` comment before each file.

## How it finds your project

1. Reads the title of VS Code's focused window, for example `index.tsx — my-app`. This works even when Chrome or another app is in front.
2. Matches `my-app` against the folders VS Code has opened (`~/Library/Application Support/Code/User/workspaceStorage`) to get the full path.
3. If nothing matches, uses the project you used most recently.

Click the menu bar icon to see which project it will use (name and path) and which Claude account and plan are logged in.

## Privacy and safety

- Runs `claude -p` locally with your own Claude Code login. No other servers.
- Claude only gets read-only tools (`Read`, `Grep`, `Glob`). It can't edit files or run commands.
- The project's `.claude/settings.json` (including hooks) is ignored (`--setting-sources user`), so a cloned repo can't run commands on your Mac.
- Chats aren't saved (`--no-session-persistence`), so nothing appears in `claude --resume`.
- MCP servers are skipped (`--strict-mcp-config`), which roughly halves startup time.
- Your prompt is passed on stdin, never through a shell string.

## Limitations

- VS Code only, not Cursor or VS Code Insiders.
- Two open projects with the same folder name: it picks the newer one.
- Every prompt is a fresh chat, so no follow-ups.
- Building from source signs ad hoc, so macOS forgets the permissions after every rebuild. To keep them, put your own certificate's SHA-1 (from `security find-identity -v -p codesigning`) in a `.sign-identity` file next to `build.sh`. It's gitignored.
- You can't see what you type. To show the prompt box, set `panel.alphaValue = 1` in `main.swift` and rebuild.

## Development

| File | What |
| --- | --- |
| `main.swift` | The whole app |
| `build.sh` | Builds `build/ClaudeClip.app`, runs the self-test, signs it ad hoc |
| `.github/workflows/release.yml` | Builds and publishes a release on every push to `main` |

Version numbers follow the commit type: `fix:` bumps the patch (`0.0.1 → 0.0.2`), `feat:` bumps the minor (`0.1.0 → 0.2.0`).

---

Not affiliated with Anthropic.
