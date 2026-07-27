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
         │ zellij action write-chars
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

### Menu (`C-c C-a`)

**Display**

| Key | Action                                                                          |
|-----|---------------------------------------------------------------------------------|
| `a` | Show AI response (dumps the zellij screen)                                      |
| `l` | Open the Claude output log (markdown, written by the Stop hook)                 |
| `x` | Clear the buffer                                                                |
| `q` | Delete session: remove the zellij session and close buffer (asks confirmation)  |

**Send**

| Key | Action                                                       |
|-----|--------------------------------------------------------------|
| `e` | Open reply buffer (write a reply while reading the response) |
| `n` | Send a number (prompts for input)                            |

**Claude Code commands**

| Key | Action                                                    |
|-----|-----------------------------------------------------------|
| `c` | Compress context (`/compact`)                                                  |
| `C` | Reset context (`/clear`)                                                       |
| `s` | Ask Claude to record progress to `CLAUDE.md`                                   |

### Reply buffer (`C-c C-a` → `e`)

Opens `*zellij-reply-session-name*`. You can read the AI's response in `*ai-session-name*` while composing your reply in the separate buffer.

| Key       | Action                              |
|-----------|-------------------------------------|
| `C-c C-c` | Send text and close the buffer      |

After sending, the original window layout is restored automatically.

### Numbered prompts

When Claude Code displays a numbered choice prompt (e.g. `❯ 1.`), the buffer updates automatically and the choices are highlighted. Send your choice with `C-c C-a` → `n`.

## Customization

To set a custom path to the `zellij` executable:

```elisp
(setq zellij-send-executable "/usr/local/bin/zellij")
```

The Claude output log location (relative to the session's working directory; keep it in sync with the hook script):

```elisp
(setq zellij-send-log-file ".zellij-send/claude-log.md")
```

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
- `zellij action write-chars` assumes UTF-8. Make sure your terminal encoding is set to UTF-8.

## How It Works

- **New session**: `zellij attach --create-background` creates a detached session; `zellij run --cwd DIR -- claude` starts the agent in a new pane and returns its pane id, which is remembered for all later commands. No attached client (terminal emulator) is needed.
- **Sending text**: `zellij action write-chars --pane-id ID` sends the text; `zellij action write --pane-id ID 13` (CR) sends Enter. Without a known pane id, the focused pane is targeted instead (requires an attached client).
- **Reading response**: `zellij action dump-screen` prints the pane content to stdout (zellij 0.44+); ANSI escapes are stripped before displaying in the buffer
- **All zellij calls are asynchronous** (`make-process` + sentinel) so Emacs never blocks
- **Auto-receive (Stop hook)**: Claude Code Stop hook → appends the latest assistant message to the markdown log, then `emacsclient` → `zellij-send--on-claude-stop` → updates all zellij-send buffers
- **Polling**: Fetches screen content every `zellij-send-poll-interval` seconds (default: 2); skips update while the user is editing (`buffer-modified-p`)
- **Reply buffer**: Opens via `pop-to-buffer`; after sending, `set-window-configuration` restores the previous window layout

## License

GPL v3 or later. See [LICENSE](LICENSE) for details.
