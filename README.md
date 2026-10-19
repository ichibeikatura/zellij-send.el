# zellij-send.el

English | [日本語](README.ja.md)

Run detached AI coding agents from Emacs. Each [zellij](https://zellij.dev/) session
becomes an ordinary Emacs buffer that you type into and read from — no terminal
emulator inside Emacs, no attached client, no window you have to keep open.

## Overview

`M-x zellij-send` creates a **detached** zellij session, starts an agent
(`claude` by default) in a pane, and gives you `*ai-session-name*` as a shared
blackboard: write your message, send it with `C-c C-c`, and the pane's screen comes
back into the same buffer.

![The blackboard buffer](Screen01.png)

The header line carries the session name and the keys you need.

Nothing is attached to the session, so nothing has to stay open. The agent keeps
working while you are somewhere else, and after an Emacs restart the dashboard picks
the running sessions back up on its own. Run several at once and it tells you which
are working, which are done, and which are waiting on an answer from you.

## Why this tool?

Emacs treats everything as text, and every buffer as equally real. A conversation with
an agent is text; so is the file it is editing, the note you are drafting, and the log
of what it said an hour ago. Putting the agent in a buffer puts it in the same world as
everything else you have open — which suits a particular way of working:

> Emacs is built on the idea that everything is text and that all buffers exist on equal
> terms. That fits people who open files from all over the place, potter about with
> whatever they feel like at the moment, and wait for the hyperfocus to arrive.

The goal is a workbench where an agent can be building software in one buffer while
another agent helps you draft prose in a second, and you move between them as your
attention moves. The point is that pottering stays cheap.

- **The agents outlive their windows.** Close the frame, restart Emacs, come back
  tomorrow — `zellij attach` in any terminal still shows you the same session.
- **Several at once is the normal case.** The [dashboard](#dashboard-zellij-send-dashboardel)
  lists every session with its state, so a stuck one is visible without visiting it.
- **Emacs composes the text, not the terminal.** Your input method, abbrevs, snippets
  and yanks from other buffers all work.
- **The conversation is a buffer.** `C-c C-a` → `a` rebuilds the whole conversation from
  Claude Code's own transcript, so what scrolled off the pane is not lost.

### If your input method breaks inside `vterm` / `eat`

This was the original reason the package exists. Emacs terminal emulators such as
`vterm` and `eat` hand key events straight to the child process — exactly what you want
for a TUI, and it means **input methods that run inside Emacs never see your keys**. An
OS-level IME (macOS, ibus, fcitx) composes text before Emacs is involved and is usually
fine; what breaks is **Emacs's own input**:

| | |
|---|---|
| Japanese | [ddSKK](https://github.com/skk-dev/ddskk) — conversion runs in Emacs Lisp |
| Chinese | [`pyim`](https://github.com/tumashu/pyim), [`emacs-rime`](https://github.com/DogLooksGood/emacs-rime) |
| Russian, Greek, … | `C-\` with `russian-computer` and friends — switching the *OS* layout would break every keybinding you have |
| Vietnamese, Indic scripts | built-in Quail methods (`vietnamese-telex`, `devanagari-itrans`, …) |
| Not a language at all | `agda-input`, `lean4-input`, the `TeX` method |

If you are in that table: compose in a regular Emacs buffer where your input works, and
let zellij-send deliver it to a pane where the TUI is happy.

## Requirements

- Emacs 28 or later (`transient` is built in)
- [zellij](https://zellij.dev/) **0.44 or later** on `$PATH`
- [`markdown-mode`](https://github.com/jrblevin/markdown-mode) (optional): Markdown decoration in the blackboard
- `python3` if you use the Stop hook or the usage display

## Installation

```elisp
;; Manual
(add-to-list 'load-path "/path/to/zellij-send")
(require 'zellij-send)

;; use-package + elpaca
(use-package zellij-send
  :ensure (zellij-send :url "https://github.com/ichibeikatura/zellij-send.el"))
```

## Usage

### 1. Open a session

`M-x zellij-send` lists the running zellij sessions; selecting one opens `*ai-session-name*`.

`[New]` asks for a working directory and a command (default `zellij-send-default-command`, i.e. `claude`) and creates a new session named after the **directory plus a two-digit counter** (`myproj00`). The session stays detached and the pane id is remembered, so no terminal needs to be attached. To watch it live, run `zellij attach SESSION` in any terminal.

When you connect to an **existing** session, its working directory, target pane and running command are recovered from zellij (the agent pane is picked from the COMMAND column of `list-panes --all`). Only if no pane can be identified is input sent to the focused pane, which then needs an attached client.

### 2. Send text

Write in the buffer and press `C-c C-c`. On success the buffer is cleared, unless you edited it while the send was in flight; failed sends keep the text.

### 3. Read the answer

The blackboard mirrors the pane continuously (`zellij subscribe`). While point is at the end of the buffer, updates keep it there; move up to read and it stays put (`M->` to follow again).

**Automatic updates pause while you are editing the buffer and after you clear it**, so a draft is never overwritten. If the screen looks frozen, `C-c C-a` → `g` brings it back.

You see one screenful — a full-screen TUI has no scrollback — so read the conversation from the start with `C-c C-a` → `a` (rebuilt from Claude Code's transcript).

## Key Bindings

Inside `*ai-session-name*`:

| Key       | Action                                  |
|-----------|-----------------------------------------|
| `C-c C-c` | Send text (buffer is cleared)           |
| `C-c C-a` | Open menu                               |
| `C-c C-k` | Interrupt what the AI is doing (sends Esc) |
| `C-c C-q` | Answer the on-screen question (AskUserQuestion) |
| `C-c C-t` | Toggle key passthrough mode (keys go to the pane) |
| `C-c C-s` | Pick and send a slash command (`C-u` re-reads the list) |
| `M-p` / `M-n` | Recall a previously sent message    |

### Menu (`C-c C-a`)

**Display**

| Key | Action                                                                          |
|-----|---------------------------------------------------------------------------------|
| `d` | Open the dashboard (all sessions at a glance)                                    |
| `a` | Show the whole conversation (from the transcript; `C-u a` dumps the screen)     |
| `g` | Back to the live pane — refetch the screen and resume automatic updates          |
| `l` | Open the Claude output log (markdown, written by the Stop hook)                 |
| `x` | Clear the buffer                                                                |
| `w` | Toggle line wrapping of the screen (for reading tables)                          |

**Send**

| Key | Action                                                       |
|-----|--------------------------------------------------------------|
| `e` | Open reply buffer (write a reply while reading the response) |
| `n` | Send a number (prompts for input)                            |
| `h` | Pick from the send history                                   |
| `u` | Answer the on-screen question (AskUserQuestion)               |
| `k` | Key passthrough mode (arrows / RET / SPC go to the pane)      |

**Commands**

| Key | Action                                                    |
|-----|-----------------------------------------------------------|
| `i` | Interrupt what the AI is doing (sends Esc)                                     |
| `/` | Pick a slash command from the minibuffer and send it (`/compact`, `/clear`, …) |
| `s` | Ask the agent to fold decisions into `CLAUDE.md` etc. (`C-u s`: a work log in a separate file) |
| `+` | Add another agent in the same directory                                        |
| `q` | Delete session: remove the zellij session and close buffer (asks confirmation) |

### Recording progress (`s`)

`s` asks the agent to fold only the lasting decisions (constraints, design decisions with their reasons, prohibitions) into its instruction file **as an update, not an append** — merge what overlaps, delete what is stale, leave out the play-by-play. The file depends on the agent: `zellij-send-progress-file-alist` (`CLAUDE.md` for claude, `AGENTS.md` for codex, `GEMINI.md` for agy).

To keep a log of the session itself, use `C-u s`: it goes to `zellij-send-progress-log-file` (default `.zellij-send/worklog-%Y-%m-%d.md`, dated) and never into `CLAUDE.md`.

### Adding agents (`+`)

Starts another agent in the **same directory, with the same command** as the current buffer, under the lowest free counter (`myproj00` → `myproj01`). `C-u C-c C-a +` lets you pick a different command. One zellij session per agent, so sending, live updates and quitting work per buffer, and the dashboard lists each on its own row.

### Multiple CLIs (Claude Code / Codex / …)

Each session can run a different command. Completion offers `zellij-send-commands` (default `("claude" "codex" "agy")`), but anything can be typed in. Buffers running something other than claude show it in the header line (`Session: myproj00 [codex]`).

| Feature | claude | codex | agy | others |
|---|---|---|---|---|
| Sending, history, reply buffer | yes | yes | yes | yes |
| Live screen (auto-receive), dashboard | yes | yes | yes | yes |
| **Key passthrough mode (`C-c C-t`)** | yes | yes | yes | yes |
| Interrupt (`C-c C-k`), quit (`q`) | yes | yes | yes | yes |
| Detecting/highlighting numbered choices | yes | yes | yes | marker-dependent |
| Answering by number (`n`, dashboard `1` `2` `3`) | yes | **no** | yes | — |
| `/clear` | yes | yes | yes | — |
| `/compact` | yes | yes | **no** | — |
| Replay the conversation (`a`), output log (`l`) | yes | — | — | — |
| Slash-command completion (`/`) | yes | — | — | — |
| Answering AskUserQuestion (`u` / automatic) | yes | — | — | — |
| Remote Control QR, usage bars | yes | — | — | — |

The bottom four rows read the shape of Claude Code's screen or its transcript, so they stop with a `user-error` on other CLIs. Use **key passthrough mode** for choices, permission dialogs and settings screens there — it does not interpret the screen, so it works with any TUI.

The `no` cells were measured on real panes. The capability tables (`zellij-send-number-reply-commands`, `zellij-send-slash-support-alist`) contain **only verified CLIs**; do not add an unverified one.

### Send history

Every message you send is remembered per session (`zellij-send-history-max`, default 50). `M-p` walks back and `M-n` forward; going past the newest entry restores your draft. `C-c C-a` → `h` picks an entry with completion.

### Slash commands (`C-c C-s`)

![Picking a slash command](Screen03.png)

Every Claude Code slash command, picked in the minibuffer. The list is read from the pane's own completion menu, so it matches what is available right now (built-ins, skills, project commands).

Commands that take an argument ask for it right after: a fixed set of choices (`/effort  [low|medium|…]`) becomes completion candidates, `<path>` becomes directory completion, and a menu you would pick from in the pane (`/config`, `/plugin`) is gathered and offered in the minibuffer, one level at a time when it nests. Typing something not in the list and pressing `RET` narrows the candidates and asks again.

Reading the list takes a few seconds, so it is prefetched in the background a few seconds after the blackboard connects and **shared per working directory**. `C-u C-c C-s` reads it again after you add a skill or a command; `zellij-send-slash-prefetch` turns the prefetch off.

The list is gathered by typing into the pane, so **nothing happens while the pane's input box has text in it**, and a fetch under way stops the moment you start typing there.

### Interrupting

`C-c C-k` (or `i` in the dashboard) sends `Esc` to the pane. It works in any state.

### Reply buffer (`C-c C-a` → `e`)

Opens `*zellij-reply-session-name*`: read the answer in the blackboard and write your reply in a separate buffer; `C-c C-c` sends it, closes the buffer and restores the window layout. The target is read from the original blackboard at send time, so once that blackboard is killed the reply cannot be sent (the text stays).

### Reading the whole conversation (`C-c C-a` → `a`)

Reads Claude Code's transcript (the JSONL under `~/.claude/projects/<slug>/`) and lays the conversation into the blackboard in order: your messages, the assistant's prose, its thinking, every tool call and result.

- On first use, pick the JSONL (newest first, shown as `MM-DD HH:MM  size  title`), even if there is only one. The choice lasts until the buffer is closed; another agent's history is never chosen by modification time. `M-x zellij-send-select-transcript` picks again.
- Automatic updates pause while it is shown; `g` goes back.
- Images become a one-line summary (`[画像 image/png 66 KB]`), and lines longer than `zellij-send-transcript-max-line-length` (default 2000) are cut. Set `zellij-send-transcript-max-block-lines` if tool outputs are too long.
- Non-Claude commands, and `C-u a`, dump the zellij screen instead.

### Back to the live pane (`C-c C-a` → `g`)

Refetches the pane and resumes automatic updates — after `a`, and equally after typing a draft you decided not to send. It asks before discarding a non-empty draft. `C-u g` includes the scrollback (only meaningful outside full-screen TUIs).

### Numbered prompts

Numbered choices (claude's `❯ 1.`, codex's `› 1.`, agy's `> 1.`) are highlighted. Send your choice with `C-c C-a` → `n`.

### Answering questions (AskUserQuestion / `C-c C-q`)

When Claude Code asks a question — the boxed UI with `❯ 1.` options, tabs across the top and a final *Review your answers* screen — zellij-send reads it from the pane, asks you in the minibuffer and presses the matching keys:

- **Single choice** — one keypress answers it; Claude Code moves on by itself.
- **Multiple choice** — pick several with `completing-read-multiple` (comma separated).
- **Other / free text** — what you type in the minibuffer is pasted into the field.
- **Review screen** — a `y/n` prompt before anything is submitted.

By default (`zellij-send-askq-auto` = `keys`) a question turns on [key passthrough mode](#key-passthrough-mode-c-c-c-t) instead of opening the minibuffer, so you can read the option descriptions on screen and answer with the number keys (`↑↓` / `RET` work too); it turns itself off when the question is gone. The window is only displayed, never selected — move to it before typing. `minibuffer` opens the minibuffer flow above automatically; `nil` leaves it to `C-c C-q`. `C-g` backs out at any point and leaves the question in the pane.

### Key passthrough mode (`C-c C-t`)

While on, the arrow keys, `RET`, `SPC`, `TAB`, `ESC`, `DEL` and ordinary characters go to the pane instead of editing the buffer — for permission dialogs, `/model`, or any menu zellij-send does not parse. `C-c C-t` (menu `k`) or `C-g` turns it off. The buffer is read-only while it is on.

## Dashboard (`zellij-send-dashboard.el`)

`M-x zellij-send-dashboard` (or `C-c C-a` → `d`) lists every open session, sorted so the ones needing your attention come first.

![The dashboard under the blackboard](Screen02.png)

| Column   | Meaning                                                            |
|----------|--------------------------------------------------------------------|
| Flag     | `✎` unsent draft / `‖` cleared — the blackboard's automatic updates are paused |
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
| `a`     | Show the conversation (`C-u`: the screen)  |
| `l`     | Open that session's log                    |
| `i`     | Interrupt what the session is doing (Esc)  |
| `c`     | Send `/compact`                            |
| `r`     | Connect to Remote Control and show its QR  |
| `Q`     | End the session (same as `C-c C-a q`)      |
| `g`     | Refresh now (`revert-buffer`)              |
| `G`     | Connect to any zellij session not yet listed |
| `?`     | Show the key list                          |

Opening the dashboard connects, without asking, to every running zellij session that has no buffer yet (`zellij-send-dashboard-auto-connect`). It rescans every `zellij-send-dashboard-scan-interval` seconds (default 15), picking up sessions started from a terminal and removing the blackboards of sessions that ended (buffers you are editing are kept).

A session counts as **working** when a spinner line is present **or** the screen changed within the last `zellij-send-dashboard-active-window` seconds (default 6). When that stops it becomes **done**, which clears once you look at that buffer. Working out the state never calls `zellij`.

`Q` asks for confirmation, sends `/exit`, waits for the agent to exit and deletes the zellij session; it force-deletes if the agent has not exited within `zellij-send-quit-timeout` seconds (default 10).

### Remote Control QR (`r`)

Connects the session under the cursor to [Remote Control](https://claude.ai/code) and shows the QR code Claude Code draws, as an image in `*zellij-qr-SESSION*`; the session URL is copied to the kill ring. It exposes a local session to claude.ai, so it always asks first, and it only works on an **idle** session.

**If you always want phone access, set `zellij-send-remote-control` to `t` instead.** New Claude Code sessions then start as `claude --remote-control SESSION` and show up in claude.ai and the mobile app under their zellij name without scanning anything.

| Option | Meaning |
|---|---|
| `zellij-send-dashboard-remote-control-timeout` | How long to wait for the screens (default 40s) |
| `zellij-send-dashboard-remote-control-poll` | Polling interval while waiting (default 1.5s) |
| `zellij-send-dashboard-qr-module-size` | Pixels per QR module (default 4) |

### Display options

| Option                                  | Meaning                                                     |
|-----------------------------------------|-------------------------------------------------------------|
| `zellij-send-dashboard-display-action`  | `display-buffer` action (default: below, fit height)        |
| `zellij-send-dashboard-fit-window`      | Re-fit the height on every refresh (default `t`)            |
| `zellij-send-dashboard-max-height`      | Height cap in lines (default 16)                            |
| `zellij-send-dashboard-tail-width`      | Width of the 状況 column (default 40)                       |
| `zellij-send-dashboard-refresh-interval`| Redraw interval in seconds (default 3)                      |
| `zellij-send-dashboard-scan-interval`   | Seconds between session scans (default 15; 0 disables)      |
| `zellij-send-dashboard-prune-gone`      | Drop rows for sessions that ended (default `t`)             |

`zellij-send.el` itself does not depend on the dashboard.

### Usage limits (`/usage`) in the dashboard

The dashboard can show the session/weekly limits that `/usage` prints, one line per limit under the table. The only supported source for this data is the JSON Claude Code pipes to a **statusLine command** on stdin, so set up a status line that caches it and the dashboard reads the cache.

**1. Create `~/.claude/hooks/statusline-zellij-send.sh`:**

```sh
#!/bin/sh
CACHE="$HOME/.claude/zellij-send-usage.json"
TMP="$CACHE.$$.tmp"

input=$(cat)

# Rate limits come from an API response, so a session that has not made a
# request yet sends JSON without them. The cache is one file shared by every
# session and the last writer wins, so writing that payload as-is would blank
# out a reading the dashboard was happily showing. Carry the previous value
# over when the new payload has none — and restore the previous mtime with it,
# since the dashboard labels the reading with the file's age.
ZS_INPUT="$input" ZS_CACHE="$CACHE" ZS_TMP="$TMP" python3 - <<'PY' 2>/dev/null || printf '%s' "$input" > "$TMP" 2>/dev/null
import json, os

cache, tmp = os.environ["ZS_CACHE"], os.environ["ZS_TMP"]
new = json.loads(os.environ["ZS_INPUT"])
mtime = None

if not new.get("rate_limits"):
    try:
        with open(cache) as f:
            old = json.load(f)
        if old.get("rate_limits"):
            new["rate_limits"] = old["rate_limits"]
            mtime = os.path.getmtime(cache)
    except Exception:
        pass

with open(tmp, "w") as f:
    json.dump(new, f)
if mtime is not None:
    os.utime(tmp, (mtime, mtime))
PY

# Write then rename, so Emacs never reads a half-written file
mv -f "$TMP" "$CACHE" 2>/dev/null
rm -f "$TMP" 2>/dev/null

# Printing nothing hides the status line in the TUI — the cache is still written,
# so the dashboard keeps working. To keep a status line, print it here instead:
#   printf '%s' "$input" | jq -r '"\(.model.display_name) | \(.workspace.current_dir)"'
exit 0
```

`chmod +x ~/.claude/hooks/statusline-zellij-send.sh`

**2. Register it in `~/.claude/settings.json`** (restart Claude Code afterwards):

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/.claude/hooks/statusline-zellij-send.sh"
  }
}
```

Rate limits are only present for Claude subscription accounts, and only after a session's first API response.

| Option                                        | Meaning                                             |
|-----------------------------------------------|-----------------------------------------------------|
| `zellij-send-dashboard-show-usage`            | Set to `nil` to hide the usage block (default `t`)  |
| `zellij-send-dashboard-usage-file`            | Cache path (default `~/.claude/zellij-send-usage.json`) |
| `zellij-send-dashboard-usage-bar-width`       | Bar width in columns (default 24)                   |
| `zellij-send-dashboard-usage-bar-style`       | `face` coloured spaces (default), `block` █ glyphs, `ascii` `#`/`-` |
| `zellij-send-dashboard-usage-light-ratio`     | How much paler the session bar is (default 0.4; 0 makes them identical) |
| `zellij-send-dashboard-usage-timezone`        | Timezone label; `nil` uses `$TZ`, then `%Z`         |

## Customization

```elisp
;; The zellij executable
(setq zellij-send-executable "/usr/local/bin/zellij")

;; Commands offered for new sessions, and the default
(setq zellij-send-commands '("claude" "codex" "agy"))
(setq zellij-send-default-command "claude")

;; Claude output log (relative to the working directory; keep in sync with the hook)
(setq zellij-send-log-file ".zellij-send/claude-log.md")

;; Files `s' asks the agent to update, and the `C-u s' work log
(setq zellij-send-progress-file-alist
      '(("claude" . "CLAUDE.md") ("codex" . "AGENTS.md") ("agy" . "GEMINI.md")))
(setq zellij-send-progress-log-file ".zellij-send/worklog-%Y-%m-%d.md")
```

### Session size

A background session created by `[New]` is only 50 columns by 48 lines by default, and Claude Code hard-wraps its output to the pane width, so paragraphs arrive shredded. zellij-send widens new sessions by attaching for a moment; `M-x zellij-send-resize-session` widens an existing one. Attaching from a terminal shrinks the session to that client's size — that is how zellij works.

| Option | Meaning |
|---|---|
| `zellij-send-session-size` | (COLUMNS . LINES) for new sessions (default `(320 . 80)`; `nil` disables) |
| `zellij-send-resize-detach-delay` | Seconds before the resize client detaches (default 2.0) |
| `zellij-send-resize-timeout` | Seconds before the resize client is killed no matter what (default 8.0) |
| `zellij-send-max-blank-lines` | Squeeze runs of blank lines down to this many (default 2; `nil` keeps them) |

### Column alignment and wrapping

The blackboard mirrors a 320-column screen. Emacs in a Japanese environment counts box-drawing characters and arrows (`─` `←`) as two columns where zellij counts one, so tables and frames drift. Inside the blackboard only, column widths follow zellij, and in a GUI frame symbols that do not fit one column are drawn with a scaled-down glyph.

| Option | Meaning |
|---|---|
| `zellij-send-grid-align` | Align the blackboard's columns with the zellij screen (default `t`) |
| `zellij-send-grid-symbol-families` | Fonts tried, in order, to fit symbols into one column |
| `zellij-send-wrap-screen` | Wrap the screen at the window width (default `t`); toggle per buffer with `C-c C-a` → `w` |

Drafts and transcripts always wrap.

### Answering questions

| Option | Meaning |
|---|---|
| `zellij-send-askq-auto` | What a question opens: `keys` (key passthrough, default), `minibuffer`, `nil` |
| `zellij-send-askq-settle-delay` | Seconds to wait after a keypress before reading the screen (default 0.8) |
| `zellij-send-askq-max-rounds` | Give up after this many questions in one run (default 12) |

## Auto-receive & Markdown Log Setup (Claude Code Stop Hook)

The blackboard is kept live by `zellij subscribe`, so everything works without a hook. With the Stop hook installed, every finished response also:

1. **Markdown log**: appends the latest assistant message from the transcript to `.zellij-send/claude-log.md` in the working directory (open with `C-c C-a` → `l`).
2. **Screen refresh**: refetches the blackboards with `dump-screen` via `emacsclient`. This needs an Emacs server (`(server-start)` or `emacs --daemon`).

### 1. Create the hook script

`~/.claude/hooks/stop-zellij-send.sh` (requires `python3`):

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

`chmod +x ~/.claude/hooks/stop-zellij-send.sh`. Add `.zellij-send/` to your `.gitignore` if you don't want the log committed.

### 2. Register the hook

`~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/stop-zellij-send.sh" } ] }
    ]
  }
}
```

## Troubleshooting

**No sessions found**
- Run `zellij list-sessions` in a terminal to check there is output.
- Check the path in `zellij-send-executable`.

**The blackboard stopped updating**
- Automatic updates pause while you are editing and after a clear. `C-c C-a` → `g` brings the live screen back.
- The dashboard's flag column shows `✎` / `‖` in that state.

**The Stop hook does nothing**
- Check that the Emacs server is running (`emacsclient -e t`) and that the script is executable.

**Long text shows as `[Pasted text #1 +N lines]` in the pane**
- Expected. Text is sent as a bracketed paste and Claude Code folds large pastes in its input box. The full text is still submitted.

## How It Works

- **New session**: `zellij attach --create-background` creates a detached session; it is widened by attaching for a moment, then `zellij run` starts the agent and the returned pane id is used for every later command
- **Sending**: `zellij action paste --pane-id ID` sends the text, `zellij action write --pane-id ID 13` sends Enter
- **Screen**: one `zellij subscribe --pane-id ID --format json` process per session streams the pane into the blackboard; manual refreshes use `zellij action dump-screen`
- **History**: the pane cannot provide it, so Claude Code's transcript JSONL is read directly
- **All zellij calls are asynchronous** (`make-process` + sentinel); Emacs never blocks

## License

GPL v3 or later. See [LICENSE](LICENSE) for details.
