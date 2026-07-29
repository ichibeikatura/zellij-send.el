# zellij-send.el

English | [日本語](README.ja.md)

An Emacs package for sending text to [zellij](https://zellij.dev/) session panes — designed for use with AI coding agents like Claude Code.

## Overview

Use the `*ai-session-name*` buffer as a shared blackboard: write your message, send it, read the AI's response, and repeat.

![Screen](Screen.png)

```
┌──────────────────────────────────────┐
│  Emacs: *ai-mysession*               │
│  ──────────────────────────────────  │
│  Explain the intent of this code     │
│                                      │
│  C-c C-c → send → buffer cleared    │
│  C-c C-a → menu                     │
└──────────────────────────────────────┘
         │ zellij action paste
         ▼
┌──────────────────────────────────────┐
│  zellij: mysession                   │
│  Claude Code is replying...          │
└──────────────────────────────────────┘
```

## Why this tool?

Emacs terminal emulators like `vterm` and `eat` pass key events directly to the child process, which means Emacs input methods (e.g. ddSKK) do not work inside them.

`shell-mode` and `eshell` do support input methods, but they are not suited for running interactive TUI applications like Claude Code.

This tool bridges the gap: compose text in a regular Emacs buffer (where your input method works normally), and have it sent to a zellij session (where TUI apps run fine).

## Requirements

- Emacs 28 or later (`transient` is built in)
- [zellij](https://zellij.dev/) **0.44 or later** installed and available on `$PATH` (older versions have a different `dump-screen` CLI and cannot target panes by id)
- [`markdown-mode`](https://github.com/jrblevin/markdown-mode) (optional): enables Markdown font decoration when installed

## Installation

### Manual

Put `zellij-send.el` on your load path and add to `init.el`:

```elisp
(add-to-list 'load-path "/path/to/zellij-send")
(require 'zellij-send)
```

### use-package + elpaca (recommended)

```elisp
(use-package zellij-send
  :ensure (zellij-send
           :url "https://github.com/ichibeikatura/zellij-send.el"))
```

### use-package (manual load path)

```elisp
(use-package zellij-send
  :load-path "/path/to/zellij-send")
```

## Usage

### 1. Open a session

```
M-x zellij-send
```

A list of running zellij sessions is shown. Selecting one opens the `*ai-session-name*` buffer.

Select `[New]` to create a new zellij session. You will be prompted for a working directory; the directory name becomes the session name. A **detached** (background) zellij session is created, and the command configured in `zellij-send-default-command` (default: `claude`) is launched in a new pane. The pane id is remembered, so no terminal client needs to be attached — everything works in the background. To watch the session live, run `zellij attach SESSION` in any terminal.

For **existing** sessions (not created by this package), the pane id is unknown, so input is sent to the focused pane. This requires at least one attached client (e.g. your terminal); fully detached foreign sessions will not receive input.

### 2. Send text

Type your message in the buffer and press `C-c C-c` to send. The buffer is cleared automatically after sending.

### 3. Read the AI's response

When Claude Code finishes its reply, the `*ai-session-name*` buffer **updates automatically**.

To fetch manually, open the menu with `C-c C-a` and press `a`.

## Key Bindings

Inside the `*ai-session-name*` buffer:

| Key       | Action                                  |
|-----------|-----------------------------------------|
| `C-c C-c` | Send text (buffer is cleared)           |
| `C-c C-a` | Open menu                               |
| `C-c C-k` | Interrupt what the AI is doing (sends Esc) |
| `C-c C-q` | Answer the on-screen question (AskUserQuestion) |
| `C-c C-t` | Toggle key passthrough mode (keys go to the pane) |
| `M-p` / `M-n` | Recall a previously sent message    |

### Menu (`C-c C-a`)

**Display**

| Key | Action                                                                          |
|-----|---------------------------------------------------------------------------------|
| `d` | Open the dashboard (all sessions at a glance)                                    |
| `a` | Show AI response (dumps the zellij screen)                                      |
| `l` | Open the Claude output log (markdown, written by the Stop hook)                 |
| `x` | Clear the buffer                                                                |

**Send**

| Key | Action                                                       |
|-----|--------------------------------------------------------------|
| `e` | Open reply buffer (write a reply while reading the response) |
| `n` | Send a number (prompts for input)                            |
| `h` | Pick from the send history                                   |
| `u` | Answer the on-screen question (AskUserQuestion)               |
| `k` | Key passthrough mode (arrows / RET / SPC go to the pane)      |

**Claude Code commands**

| Key | Action                                                    |
|-----|-----------------------------------------------------------|
| `i` | Interrupt what the AI is doing (sends Esc)                                     |
| `c` | Compress context (`/compact`)                                                  |
| `C` | Reset context (`/clear`)                                                       |
| `s` | Ask Claude to record progress to `CLAUDE.md`                                   |
| `q` | Delete session: remove the zellij session and close buffer (asks confirmation) |

### Send history

Every message you send is remembered per session (`zellij-send-history-max`, default 50). `M-p` walks back through it and `M-n` forward; going past the newest entry restores whatever you had typed before you started browsing. `C-c C-a` → `h` picks an entry with completion. The history is shared between the blackboard and the reply buffer, and survives closing either.

### Interrupting

`C-c C-k` (or `i` in the dashboard) sends `Esc` to the pane, which is how you stop Claude Code mid-answer. It works in any state on purpose: the dashboard's status is a few seconds old, so refusing to interrupt a session that merely *looks* idle would be the wrong call.

### Reply buffer (`C-c C-a` → `e`)

Opens `*zellij-reply-session-name*`. You can read the AI's response in `*ai-session-name*` while composing your reply in the separate buffer.

| Key       | Action                              |
|-----------|-------------------------------------|
| `C-c C-c` | Send text and close the buffer      |

After sending, the original window layout is restored automatically.

### Numbered prompts

When Claude Code displays a numbered choice prompt (e.g. `❯ 1.`), the buffer updates automatically and the choices are highlighted. Send your choice with `C-c C-a` → `n`.

### Answering questions (AskUserQuestion)

When Claude Code asks you a question — the boxed UI with `❯ 1.` options, tabs across the top and a final *Review your answers* screen — you no longer have to switch to the terminal to work the arrow keys.

The blackboard buffer already mirrors the pane, so zellij-send reads the question straight out of it, asks you in the minibuffer, and presses the matching keys in the pane for you:

- **Single choice** — pick with completion; one keypress answers it and Claude Code moves to the next question by itself.
- **Multiple choice** (`multiSelect`) — pick several with `completing-read-multiple` (comma separated). zellij-send toggles exactly the options whose state needs to change, then walks to the confirmation screen.
- **Other / free text** — choose `Type something`, type your answer in the minibuffer, and it is pasted into the field.
- **Review screen** — you get a `y/n` prompt before anything is submitted; answering `n` cancels.

By default the minibuffer opens on its own the moment a question appears (`zellij-send-askq-auto`). Set it to `nil` if you would rather trigger it yourself with `C-c C-q` (or `C-c C-a` → `u`). `C-g` backs out at any point and leaves the question untouched in the pane.

### Key passthrough mode (`C-c C-t`)

Sometimes you want the raw keys — a permission dialog, `/model`, a menu zellij-send does not parse. Toggle key passthrough mode and the arrow keys, `RET`, `SPC`, `TAB`, `ESC`, `DEL` and ordinary characters are sent to the pane instead of editing the buffer. The header line and the mode line (` →zellij`) tell you it is on; `C-c C-t` or `C-g` turns it off. The buffer is read-only while it is on, so a stray keystroke cannot stall the automatic screen updates.

## Dashboard (`zellij-send-dashboard.el`)

`M-x zellij-send-dashboard` (or `C-c C-a` → `d`) lists every open session in one table, sorted so the ones needing your attention come first.

```
   状態        セッション      経過   無変化  状況
 ❓ 選択待ち   proj-a          12s    3s     ❯ 1. Yes
 ☝ 完了       proj-b          1m04   1m04   Done — 3 files changed
 ✍ 作業中     proj-c          8s     0s     ✳ Frobnicating… (12s · esc to interrupt)
 · 待機       proj-d          5m21   5m21   ❯
```

| Column   | Meaning                                                            |
|----------|--------------------------------------------------------------------|
| Flag     | `✎` unsent draft / `‖` cleared — polling is paused, display is stale |
| 状態     | Waiting for choice / Done / Working / Idle                          |
| 経過     | Time since entering the current state                               |
| 無変化   | Time since the screen last changed (spots stuck sessions)           |
| 状況     | Last meaningful line of the screen (e.g. the spinner)               |

| Key     | Action                                     |
|---------|--------------------------------------------|
| `RET`   | Jump to the session buffer                 |
| `o`     | Show it in another window, stay here       |
| `e`     | Open a reply buffer for that session       |
| `1`/`2`/`3` | Send that numbered choice              |
| `a`     | Fetch the screen manually                  |
| `l`     | Open that session's log                    |
| `i`     | Interrupt what the session is doing (Esc)  |
| `c`     | Send `/compact`                            |
| `r`     | Connect to Remote Control and show its QR  |
| `Q`     | End the session — only if it is idle       |
| `k`     | Delete the session (any state)             |
| `g`     | Refresh now (`revert-buffer`)              |
| `G`     | Connect to any zellij session not yet listed |
| `?`     | Show the key list                          |

The bindings follow Emacs convention: `g` refreshes (`revert-buffer-function` is replaced too, so `M-x revert-buffer` and mouse-driven reverts run the same refresh), the stronger `G` connects, and `?` lists the keys in `*zellij-dashboard-help*` (`q` closes it). `C-h m` works as well.

Opening the dashboard **connects to every running zellij session** that does not have a buffer yet (`zellij-send-dashboard-auto-connect`, default `t`). No prompts: the working directory comes from `zellij action dump-layout` and the pane id from `zellij action list-panes` (the pane titled after `zellij-send-default-command` wins, otherwise the first terminal pane). Because the pane id is recovered this way, sessions you connect to now accept input without a terminal client attached — including after an Emacs restart.

Connecting is not a one-shot at startup: the list is rescanned every `zellij-send-dashboard-scan-interval` seconds (default 15), so **a zellij session you start in the terminal while Emacs is already running shows up on its own** (press `G` if you want it immediately). The same scan kills the blackboard buffer of any session that has disappeared from `zellij list-sessions`, removing its row (`zellij-send-dashboard-prune-gone`, default `t`). Buffers you are editing (`buffer-modified-p`) are kept so unsent text is never lost, and a `list-sessions` timeout is not treated as "no sessions", so rows are never pruned on a hiccup. This scan is the only thing that calls `zellij`; the 3-second redraw just reads buffer contents.

State is derived from each session buffer's contents — no extra `zellij` calls are made. A session counts as **working** when the spinner line is present (`zellij-send-dashboard-working-regexp`, default `esc to interrupt`) **or** the screen changed within the last `zellij-send-dashboard-active-window` seconds (default 6). The screen check matters: while Claude Code streams plain prose it shows no spinner at all, so spinner-only detection reports an actively answering session as idle. When neither holds, the session flips to **done**, which clears once you look at that buffer.

`Q` refuses to act on a session that is working, waiting for a choice, or freshly done, so a stray keypress cannot kill a session mid-task; `k` has no such guard.

### Remote Control QR (`r`)

`r` connects the session under the cursor to [Remote Control](https://claude.ai/code) and shows its QR code in Emacs, so you can carry on from your phone.

Claude Code draws the QR itself using half-block characters, so no QR generator is needed — zellij-send sends `/remote-control` to the pane, waits for the menu, picks **Show QR code**, captures the screen, and dismisses the overlay with `Esc` so the pane returns to its prompt. The session URL is extracted too and copied to the kill ring.

Because this exposes a local session to claude.ai, `r` always asks for confirmation, and — like `Q` — it only works on an **idle** session, since it types into the pane.

| Option                                            | Meaning                                        |
|---------------------------------------------------|------------------------------------------------|
| `zellij-send-dashboard-remote-control-timeout`    | How long to wait for the screens (default 40s) |
| `zellij-send-dashboard-remote-control-poll`       | Polling interval while waiting (default 1.5s)  |

Connecting takes ~10 seconds, so the wait is a poll with a timeout rather than a fixed sleep. The QR is shown in `*zellij-qr-SESSION*` as an **SVG image**, not as text: the half-block characters are parsed back into a module matrix (`█` = both, `▀` = upper, `▄` = lower) and redrawn as black squares on white with a 4-module quiet zone. Drawing it as text depends on the font's glyph metrics and usually will not scan. Size it with `zellij-send-dashboard-qr-module-size` (pixels per module, default 4 — about 165px for a 33-module code). If the frame has no SVG support the text version is used, with block characters forced to one column wide.

By default the dashboard opens below the current window, sized to fit its contents rather than taking over the frame:

| Option                                  | Meaning                                                     |
|-----------------------------------------|-------------------------------------------------------------|
| `zellij-send-dashboard-display-action`  | `display-buffer` action (default: below, fit height)        |
| `zellij-send-dashboard-fit-window`      | Re-fit the height on every refresh (default `t`)            |
| `zellij-send-dashboard-max-height`      | Height cap in lines (default 16)                            |
| `zellij-send-dashboard-tail-width`      | Width of the 状況 column (default 40)                       |
| `zellij-send-dashboard-refresh-interval`| Redraw interval in seconds (default 3; too short makes the list hard to navigate) |
| `zellij-send-dashboard-scan-interval`   | Seconds between session scans (default 15; 0 disables auto-detection) |
| `zellij-send-dashboard-prune-gone`      | Drop rows for sessions that ended (default `t`)             |

The dashboard requires `zellij-send-dashboard.el` to be on your load path; `zellij-send.el` itself does not depend on it.

### Usage limits (`/usage`) in the dashboard

The dashboard can show the same session/weekly limits that `/usage` prints inside Claude Code:

```
── 使用状況 ─ 12s前の記録 ─────────────
Current session:███████▌               30% used Resets 6:40pm (Asia/Tokyo)
Current week   :███████▎               29% used Resets Jul 29 at 9pm (Asia/Tokyo)
```

It sits under the table, one line per limit, so it costs three lines of height.

The bar is drawn as spaces with a background colour rather than block glyphs (`█`), because in some fonts (M PLUS, for one) the block glyph is taller than the line box and the bar breaks up. Set `zellij-send-dashboard-usage-bar-style` to `block` or `ascii` if you prefer.

`/usage` only exists inside the TUI and the `claude` CLI has no `usage` subcommand, so this data has exactly one supported source: the JSON that Claude Code pipes to a **statusLine command** on stdin. Set up a status line that caches that JSON and the dashboard reads the cache — no extra processes, no undocumented APIs.

**1. Create `~/.claude/hooks/statusline-zellij-send.sh`:**

```sh
#!/bin/sh
CACHE="$HOME/.claude/zellij-send-usage.json"
TMP="$CACHE.$$.tmp"

input=$(cat)

# Write then rename, so Emacs never reads a half-written file
printf '%s' "$input" > "$TMP" 2>/dev/null && mv -f "$TMP" "$CACHE" 2>/dev/null
rm -f "$TMP" 2>/dev/null

# Printing nothing hides the status line in the TUI — the cache is still written,
# so the dashboard keeps working. To keep a status line, print it here instead:
#   printf '%s' "$input" | jq -r '"\(.model.display_name) | \(.workspace.current_dir)"'
exit 0
```

`chmod +x ~/.claude/hooks/statusline-zellij-send.sh`

**2. Register it in `~/.claude/settings.json`:**

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/.claude/hooks/statusline-zellij-send.sh"
  }
}
```

Restart Claude Code (or open `/statusline` once) so the new status line takes effect.

The script above prints nothing, so no status line appears in Claude Code — the hook still runs on every update, which is all the cache needs. Print something there if you want the TUI status line back.

The cache is refreshed by any running Claude Code session, so the dashboard shows how old the reading is (`12s前の記録`). Rate limits are only present for Claude subscription accounts, and only after the first API response of a session.

| Option                                        | Meaning                                             |
|-----------------------------------------------|-----------------------------------------------------|
| `zellij-send-dashboard-show-usage`            | Set to `nil` to hide the usage block (default `t`)  |
| `zellij-send-dashboard-usage-file`            | Cache path (default `~/.claude/zellij-send-usage.json`) |
| `zellij-send-dashboard-usage-bar-width`       | Bar width in columns (default 24)                   |
| `zellij-send-dashboard-usage-bar-style`       | `face` coloured spaces (default), `block` █ glyphs, `ascii` `#`/`-` |
| `zellij-send-dashboard-usage-timezone`        | Timezone label; `nil` uses `$TZ`, then `%Z`         |

## Customization

To set a custom path to the `zellij` executable:

```elisp
(setq zellij-send-executable "/usr/local/bin/zellij")
```

The Claude output log location (relative to the session's working directory; keep it in sync with the hook script):

```elisp
(setq zellij-send-log-file ".zellij-send/claude-log.md")
```

Question answering (see [Answering questions](#answering-questions-askuserquestion)):

| Option                            | Meaning                                                                    |
|-----------------------------------|----------------------------------------------------------------------------|
| `zellij-send-askq-auto`           | Open the minibuffer as soon as a question appears (default `t`)            |
| `zellij-send-askq-settle-delay`   | Seconds to wait after a keypress before reading the screen (default `0.8`) |
| `zellij-send-askq-max-rounds`     | Give up after this many questions in one run (default 12)                  |

### Session width

A session created by `zellij attach --create-background` is only **50 columns by 48 lines**. Claude Code hard-wraps its own output to the pane width, so paragraphs would arrive shredded into short lines.

Setting `COLUMNS` / `LINES` does not help — measured on zellij 0.44.3 against a freshly started, isolated server (`ZELLIJ_SOCKET_DIR`), `COLUMNS=320 LINES=80`, `COLUMNS=200 LINES=60` and no setting at all all produce the same 50x48 pane. Floating panes with an explicit `--width` get clamped to the viewport, and there is no config-file setting for it.

What does work is attaching a client whose pty has the size you want and detaching again: the size sticks, and panes created afterwards inherit it. zellij-send does this automatically when it creates a session, before starting the agent pane:

```elisp
(setq zellij-send-session-size '(320 . 80))   ; nil disables the resize
(setq zellij-send-resize-detach-delay 2.0)    ; wait before sending Ctrl+o d
(setq zellij-send-resize-timeout 8.0)         ; kill the client no matter what
```

The attach client is short-lived (about 2 seconds), fully asynchronous, and its output is discarded by a filter — Emacs must keep reading the pty, otherwise the zellij server blocks writing to the client and the whole session stops accepting input. If the detach keystroke does not work (for example because you rebound it), the watchdog kills the client after `zellij-send-resize-timeout`; the session survives that and keeps the new size.

To widen a session that already exists, run `M-x zellij-send-resize-session` from its buffer. Sessions you start yourself from a terminal already take that terminal's width, so this only matters for sessions zellij-send creates via `[New]`.

Attaching from a terminal shrinks the session to that client's size — that is how zellij works. Don't attach if you want to keep the full width.

## Auto-receive & Markdown Log Setup (Claude Code Stop Hook)

The Stop hook does two things every time Claude Code finishes a response:

1. **Markdown log**: extracts the latest assistant message from the transcript and appends it to `.zellij-send/claude-log.md` in the working directory (open it with `C-c C-a` → `l`). Useful for reviewing what Claude said earlier in a long session.
2. **Auto-receive**: updates the `*ai-session-name*` buffer via `emacsclient`. This part requires an Emacs server to be running (`(server-start)` or `emacs --daemon`).

### 1. Create the hook script

Create `~/.claude/hooks/stop-zellij-send.sh` (requires `python3`):

```sh
#!/bin/sh
# The hook JSON is passed via an env var because the heredoc occupies stdin
ZJS_HOOK_INPUT=$(cat)
export ZJS_HOOK_INPUT

/usr/bin/python3 - <<'PY' 2>/dev/null
import json, os, datetime

data = json.loads(os.environ.get("ZJS_HOOK_INPUT") or "{}")
transcript_path = data.get("transcript_path")
cwd = data.get("cwd") or ""

if transcript_path and cwd and os.path.isfile(transcript_path):
    last = None
    with open(transcript_path) as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") != "assistant":
                continue
            msg = rec.get("message") or {}
            texts = [c.get("text", "")
                     for c in (msg.get("content") or [])
                     if isinstance(c, dict) and c.get("type") == "text"]
            text = "\n\n".join(t for t in texts if t.strip())
            if text.strip():
                last = text
    if last:
        log_dir = os.path.join(cwd, ".zellij-send")
        os.makedirs(log_dir, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(os.path.join(log_dir, "claude-log.md"), "a") as out:
            out.write("\n## %s\n\n%s\n" % (stamp, last))
PY

# Run emacsclient in the background with a 10s watchdog so a busy/frozen
# Emacs never blocks the Stop hook
(
  emacsclient -e "(zellij-send--on-claude-stop)" >/dev/null 2>&1 &
  EC_PID=$!
  sleep 10
  kill "$EC_PID" 2>/dev/null
) &
exit 0
```

Then make it executable:

```sh
chmod +x ~/.claude/hooks/stop-zellij-send.sh
```

Tip: add `.zellij-send/` to your `.gitignore` (or global gitignore) if you don't want the log committed.

### 2. Register the hook in Claude Code settings

`~/.claude/settings.json` (the path and format may vary depending on your Claude Code version):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/stop-zellij-send.sh"
          }
        ]
      }
    ]
  }
}
```

With this in place, the `*ai-session-name*` buffer updates every time Claude Code finishes a response.

## Troubleshooting

**"No zellij sessions found"**
- Make sure zellij is running.
- Run `zellij list-sessions` in a terminal to verify there is output.
- Check that `zellij-send-executable` points to the correct path (`M-x describe-variable RET zellij-send-executable`).

**Auto-receive not working (buffer not updating)**
- Make sure the Emacs server is running (`M-x server-start` or `emacs --daemon`).
- Run `emacsclient -e t` in a terminal to verify the connection.
- Check that `~/.claude/hooks/stop-zellij-send.sh` is executable (`chmod +x`).

**Garbled characters / text not sending**
- `zellij action paste` assumes UTF-8. Make sure your terminal encoding is set to UTF-8.

**Long text shows as `[Pasted text #1 +N lines]` in the pane**
- Expected. Text is sent with `zellij action paste` (bracketed paste), and Claude Code collapses
  large pastes into a placeholder in its input box. The full text is still submitted; only the
  pane's display is collapsed, so the `*ai-SESSION*` buffer mirrors the placeholder rather than
  the body.

## How It Works

- **New session**: `zellij attach --create-background` creates a detached session; `zellij run --cwd DIR -- claude` starts the agent in a new pane and returns its pane id, which is remembered for all later commands. No attached client (terminal emulator) is needed.
- **Sending text**: `zellij action paste --pane-id ID` sends the text as a bracketed paste; `zellij action write --pane-id ID 13` (CR) sends Enter. Without a known pane id, the focused pane is targeted instead (requires an attached client). `paste` is used instead of `write-chars` because `write-chars` passes newlines through as bare LF, which a shell (or any agent that submits on LF) treats as multiple separate lines. `paste` wraps the text in bracketed-paste markers only when the receiving pane has that mode enabled, so panes that do not support it still receive plain text.
- **Reading response**: `zellij action dump-screen` prints the pane content to stdout (zellij 0.44+); ANSI escapes are stripped before displaying in the buffer
- **All zellij calls are asynchronous** (`make-process` + sentinel) so Emacs never blocks
- **Auto-receive (Stop hook)**: Claude Code Stop hook → appends the latest assistant message to the markdown log, then `emacsclient` → `zellij-send--on-claude-stop` → updates all zellij-send buffers
- **Live updates**: One long-running `zellij subscribe --pane-id ID --format json` process per session streams pane changes as NDJSON; the buffer is rewritten from the `viewport` field (which always carries the full pane, not a diff). Updates are skipped while the user is editing (`buffer-modified-p`) or after an explicit clear, but the last-change timestamp keeps being recorded so the dashboard still sees activity. An idle session produces one event (the initial delivery) rather than a `dump-screen` process every 2 seconds, and a change reaches the buffer in tens of milliseconds instead of up to 2 seconds. If the stream drops, it reconnects with exponential backoff (`zellij-send-subscribe-initial-timeout`, `zellij-send-subscribe-max-retries`, `zellij-send-subscribe-backoff-max`).
- **Reply buffer**: Opens via `pop-to-buffer`; after sending, `set-window-configuration` restores the previous window layout

## License

GPL v3 or later. See [LICENSE](LICENSE) for details.
