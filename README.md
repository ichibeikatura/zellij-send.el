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
- [zellij](https://zellij.dev/) installed and available on `$PATH`
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

Select `[New]` to create a new zellij session. You will be prompted for a working directory; the directory name becomes the session name. The command configured in `zellij-send-default-command` (default: `claude`) is launched automatically in the new session.

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

| Key | Action                                                                                         |
|-----|------------------------------------------------------------------------------------------------|
| `a` | Show AI response (dumps the zellij screen)                                                     |
| `t` | Open terminal view (eat buffer, attaches to the zellij session)                                |
| `x` | Clear the buffer                                                                               |
| `q` | Delete session: close eat buffer, remove zellij session, and close buffer (asks confirmation)  |

**Send**

| Key | Action                                                       |
|-----|--------------------------------------------------------------|
| `e` | Open reply buffer (write a reply while reading the response) |
| `n` | Send a number (prompts for input)                            |

**Claude Code commands**

| Key | Action                                                    |
|-----|-----------------------------------------------------------|
| `c` | Compress context (`/compact`)                             |
| `C` | Reset context (`/clear`)                                  |
| `s` | Ask Claude to record progress to `CLAUDE.md`              |

### Reply buffer (`C-c C-a` → `e`)

Opens `*zellij-reply-session-name*`. You can read the AI's response in `*ai-session-name*` while composing your reply in the separate buffer.

| Key       | Action                              |
|-----------|-------------------------------------|
| `C-c C-c` | Send text and close the buffer      |

After sending, the original window layout is restored automatically.

### Quick response to numbered prompts

When Claude Code displays a numbered choice prompt (e.g. `❯ 1.`), the buffer updates automatically and the choices are highlighted.

| Key | Action                      |
|-----|-----------------------------|
| `1` | Send choice 1 immediately   |
| `2` | Send choice 2 immediately   |
| `3` | Send choice 3 immediately   |

When no prompt is active, these keys insert the digit as normal.

## Mode Line Indicator

While an AI session is running, a status indicator appears in the mode line:

| State      | Display                          |
|------------|----------------------------------|
| Working    | `✍ working (session-name)`       |
| Done       | `☝ done! (session-name)`         |

When multiple sessions are active, names are shown comma-separated, e.g. `☝ done! (proj1, proj2)`.

The indicator uses `global-mode-string`. If you use [doom-modeline](https://github.com/seagle0128/doom-modeline), add the `misc-info` segment to your modeline definition:

```elisp
(doom-modeline-def-modeline 'main
  '(...)
  '(... misc-info ...))
```

The `☝ done!` indicator clears automatically when you switch to the session buffer.

## Customization

To set a custom path to the `zellij` executable:

```elisp
(setq zellij-send-executable "/usr/local/bin/zellij")
```

## Auto-receive Setup (Claude Code Stop Hook)

Automatically update the Emacs buffer whenever Claude Code finishes a response.

This requires an Emacs server to be running (`(server-start)` or `emacs --daemon`).

### 1. Create the hook script

```sh
mkdir -p ~/.claude/hooks
cat > ~/.claude/hooks/stop-zellij-send.sh << 'EOF'
#!/bin/sh
emacsclient -e "(zellij-send--on-claude-stop)" 2>/dev/null || true
EOF
chmod +x ~/.claude/hooks/stop-zellij-send.sh
```

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

- **Sending text**: `zellij action write-chars` sends the text; `zellij action write 13` (CR) sends Enter
- **Reading response**: `zellij action dump-screen` dumps the pane content to a temp file; ANSI escapes are stripped before displaying in the buffer
- **Auto-receive (Stop hook)**: Claude Code Stop hook → `emacsclient` → `zellij-send--on-claude-stop` → updates all zellij-send buffers
- **Polling**: Fetches screen content every `zellij-send-poll-interval` seconds (default: 2); skips update while the user is editing (`buffer-modified-p`)
- **Reply buffer**: Opens via `pop-to-buffer`; after sending, `set-window-configuration` restores the previous window layout

## License

GPL v3 or later. See [LICENSE](LICENSE) for details.
