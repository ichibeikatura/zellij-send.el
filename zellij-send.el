;;; zellij-send.el --- Send text to zellij sessions from Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2026 桂市兵衛
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: 桂市兵衛
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4"))
;; URL: https://github.com/ichibeikatura/zellij-send.el

;;; Commentary:
;; Emacs から zellij セッションに日本語文字列を送る拡張。
;; M-x zellij-send でセッション選択、C-c C-c で送信、C-c C-a でメニュー。

;;; Code:

(require 'transient)
(require 'seq)
(require 'cl-lib)
(require 'json)         ; transcript の JSONL を読む
(require 'parse-time)   ; transcript の timestamp（ISO 8601）を解釈する

(declare-function markdown-mode "markdown-mode")
(declare-function zellij-send-mode "zellij-send")

(defgroup zellij-send nil
  "Send text to zellij sessions."
  :group 'tools)

(defcustom zellij-send-executable "zellij"
  "Path to the zellij executable."
  :type 'string
  :group 'zellij-send)

(defcustom zellij-send-default-command "claude"
  "新規セッションで起動するコマンド。"
  :type 'string
  :group 'zellij-send)

(defcustom zellij-send-term "xterm-256color"
  "zellij をサブプロセス起動する際に設定する TERM 環境変数。
Emacs はサブプロセスに既定で TERM=dumb を渡すため、これがそのまま
zellij サーバ・ペインに継承され、ペイン内のシェルでも TERM=dumb と
なり starship 等が無効化される。サーバを起動する `attach
--create-background' とペインを生む `run' をこの値で起動して回避する。"
  :type 'string
  :group 'zellij-send)

(defcustom zellij-send-session-size '(320 . 80)
  "新規セッションを広げる大きさ (COLUMNS . LINES)。nil なら広げない。

`attach --create-background' で作った背景セッションは 50 桁 × 48 行に固定され、
**環境変数 COLUMNS / LINES では変えられない**（実測。CLAUDE.md 参照）。
唯一効くのが「この大きさの pty を持つクライアントで一瞬 attach して detach する」
方法で、`zellij-send--resize-session' がそれを行う。

Claude Code は自分でペイン幅に合わせて改行を入れて出力するので、50 桁のままだと
日本語が 24 文字程度で折り返されて読みにくい。広げておくと長い行のまま届き、
Emacs 側で好きなように折り返せる。"
  :type '(choice (const :tag "広げない" nil)
                 (cons (integer :tag "桁") (integer :tag "行")))
  :group 'zellij-send)

(defcustom zellij-send-resize-detach-delay 2.0
  "拡幅用の attach クライアントを detach するまでの待ち時間（秒）。
クライアントが繋がって pty の大きさがセッションに伝わるのを待つ。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-resize-timeout 8.0
  "拡幅用の attach クライアントを生かしておく上限（秒）。
detach が効かなくてもこの時間で必ずプロセスを殺す。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-subscribe-initial-timeout 15.0
  "subscribe 接続後、最初のイベントを待つ上限（秒）。
これを過ぎても何も来なければ接続失敗とみなして再接続する。

終了コードで失敗を判定できないため必要。存在しないセッションを指定すると
`zellij subscribe' は**終了コード 0 のまま**何も流さずに終わる（実測）。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-subscribe-max-retries 5
  "subscribe の再接続を連続で何回失敗したらあきらめるか。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-subscribe-backoff-max 30.0
  "subscribe 再接続の待ち時間の上限（秒）。1, 2, 4... と倍にしていく。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-history-max 50
  "セッションごとに覚えておく送信履歴の数。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-quit-timeout 10.0
  "`zellij-send-quit' が /exit の効果を待つ上限（秒）。
これを超えたら `delete-session --force' に切り替える。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-quit-poll-interval 0.5
  "`zellij-send-quit' がセッションの消滅を確認する間隔（秒）。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-transcript-dir "~/.claude/projects"
  "Claude Code が会話履歴（JSONL）を置くディレクトリ。"
  :type 'directory
  :group 'zellij-send)

(defcustom zellij-send-transcript-max-block-lines nil
  "transcript の 1 ブロックを表示する最大行数。nil なら省略しない。
ツールの出力（tool_result）はファイル全文を含むことがあるため、
黒板が重いときだけ数値を設定する。"
  :type '(choice (const :tag "省略しない" nil) integer)
  :group 'zellij-send)

(defcustom zellij-send-transcript-max-line-length 2000
  "transcript の 1 行を表示する最大文字数。nil なら省略しない。
画像の base64 や、tool_use の入力を JSON にしたものは改行を含まないため、
1 行が数万文字になる。折り返しで画面が埋まって読めなくなるので、
既定で切り詰める。通常の文章 1 段落は超えない長さにしてある。"
  :type '(choice (const :tag "省略しない" nil) integer)
  :group 'zellij-send)

(defcustom zellij-send-log-file ".zellij-send/claude-log.md"
  "Claude の出力ログファイルのパス（セッション作業ディレクトリからの相対）。
実際の追記は Stop フック（stop-zellij-send.sh）が行うため、
変更する場合はフックスクリプト側も合わせること。"
  :type 'string
  :group 'zellij-send)

(defvar-local zellij-send--session nil
  "このバッファに対応する zellij セッション名。")

(defvar-local zellij-send--pane-id nil
  "送信先ペインの ID（例: \"terminal_2\"）。
このパッケージが `zellij run' で起動したペインのみ判明する。
nil の場合は focused pane に送る（attach クライアントが必要）。")

(defvar-local zellij-send--subscribe-process nil
  "このバッファに紐づく `zellij subscribe' の常駐プロセス。")

(defvar-local zellij-send--subscribe-timer nil
  "初回イベント待ちタイムアウト、または再接続待ちのタイマー。")

(defvar-local zellij-send--subscribe-pending ""
  "subscribe の受信途中データ。1 イベントが約 8 KB あり複数回に分かれて届くため、
改行までを溜めてから 1 行ずつ JSON として解釈する。")

(defvar-local zellij-send--subscribe-pane-id nil
  "現在の subscribe 接続が使っている pane-id。
`zellij-send--pane-id' と食い違ったら張り直す。")

(defvar-local zellij-send--subscribe-retries 0
  "subscribe の連続失敗回数。イベントを 1 つでも受け取ったら 0 に戻す。")

(defvar-local zellij-send--last-event-time nil
  "最後に subscribe イベントを受け取った時刻（`float-time'）。")

(defvar-local zellij-send--last-change-time nil
  "画面内容が最後に変化した時刻（`float-time'）。
バッファ更新を抑止している間（編集中・クリア後）も記録し続ける。
ダッシュボードの「作業中」判定はこれを見る。")

(defvar-local zellij-send--last-content nil
  "最後に受け取った画面内容。更新を抑止していても変化の検出には使う。")

(defvar-local zellij-send--user-cleared nil
  "ユーザーが意図してクリアした場合 non-nil。自動更新・Stop フックの上書きを防ぐ。")

(defvar-local zellij-send--reply-main-buffer nil
  "返信バッファを開いた元の zellij-send バッファ。")

(defvar-local zellij-send--reply-window-config nil
  "返信バッファを開く前のウィンドウ構成。")

(defmacro zellij-send--assert-session ()
  "カレントバッファが zellij-send セッションに紐付いていなければエラーを発する。"
  '(unless zellij-send--session
     (user-error "zellij-send バッファ外では使えません")))

;;; セッション一覧の取得

(defun zellij-send--parse-sessions (raw)
  "RAW テキスト（list-sessions 出力）から生存セッション名リストを返す。
zellij の出力は 1 行 1 セッションで
「NAME [Created ...] (current)」の形式（ANSI 付き）。
以下は除外する:
- EXITED セッション（送信しても届かないため）
- セッションが 0 件のときの案内文
  （\"No active zellij sessions found.\" — 従来はこれを
  セッション名 \"No\" として拾ってしまっていた）。"
  (delq nil
        (mapcar (lambda (line)
                  (let ((clean (string-trim (zellij-send--strip-ansi line))))
                    (when (and (string-match "\\`\\([^ \t]+\\)[ \t]+\\[Created" clean)
                               (not (string-match-p "EXITED" clean)))
                      (match-string 1 clean))))
                (split-string raw "\n" t))))

(defun zellij-send--list-sessions-async (callback)
  "list-sessions を非同期で実行し CALLBACK を呼ぶ。
成功時: (callback sessions) — sessions は文字列リスト（空もあり）。
タイムアウト時（5秒）: (callback :timeout)。"
  (let* ((out-buf (generate-new-buffer " *zellij-list-sessions*"))
         (err-buf (generate-new-buffer " *zellij-list-sessions-err*"))
         (done nil)
         timer proc)
    (setq proc
          (make-process
           :name "zellij-list-sessions"
           :buffer out-buf
           :stderr err-buf
           :noquery t
           :command (list zellij-send-executable "list-sessions")
           :sentinel
           (lambda (p _)
             (when (and (not done)
                        (memq (process-status p) '(exit signal)))
               (setq done t)
               (when timer (cancel-timer timer))
               (let ((sessions (zellij-send--parse-sessions
                                (with-current-buffer out-buf (buffer-string)))))
                 (ignore-errors (kill-buffer out-buf))
                 (ignore-errors (kill-buffer err-buf))
                 (funcall callback sessions))))))
    (setq timer
          (run-with-timer 5.0 nil
                          (lambda ()
                            (unless done
                              (setq done t)
                              (ignore-errors (delete-process proc))
                              (ignore-errors (kill-buffer out-buf))
                              (ignore-errors (kill-buffer err-buf))
                              (funcall callback :timeout)))))))

;;; バッファ管理

(defun zellij-send--buffer-name (session)
  "SESSION に対応するバッファ名を返す。"
  (format "*ai-%s*" session))

(defun zellij-send--get-or-create-buffer (session)
  "SESSION 用バッファを返す。なければ作成して zellij-send-mode を有効化。"
  (let* ((name (zellij-send--buffer-name session))
         (buf (get-buffer-create name)))
    (with-current-buffer buf
      (unless (eq major-mode 'zellij-send-mode)
        (zellij-send-mode)
        (setq zellij-send--session session))
      ;; pane-id が未確定でも呼んでよい（ensure が特定してから張る）
      (zellij-send--subscribe-ensure))
    buf))

;;; 送信

(defun zellij-send--process-environment ()
  "zellij を起動するための `process-environment' を返す。
TERM を `zellij-send-term' に差し替える（Emacs 既定の TERM=dumb が
zellij サーバ・ペインに継承されるのを防ぐ）。

かつてここで COLUMNS / LINES も渡していた（`zellij-send-session-size'）が、
**zellij 0.44.3 では効果が無いと実測で確認したので削除した**。
背景セッションは 50 桁 × 48 行で固定される。詳細は CLAUDE.md
「背景セッションの大きさ」を参照。"
  (cons (concat "TERM=" zellij-send-term) process-environment))

(defun zellij-send--zellij-async (args &optional callback)
  "zellij を ARGS で非同期実行する。
終了したら CALLBACK に exit code を渡して呼ぶ（CALLBACK は省略可）。
同期 `call-process' は使わない: Emacs の UI をブロックし、
zellij サーバ側の都合で応答が遅れた場合にフリーズするため。
TERM を上書きして起動する（サーバを起動する `attach
--create-background' が TERM=dumb をペインに伝播させないため）。"
  (let ((process-environment (zellij-send--process-environment)))
    (make-process
     :name "zellij-async"
     :buffer nil
     :noquery t
     :command (cons zellij-send-executable args)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (when callback
           (funcall callback (process-exit-status proc))))))))

(defun zellij-send--pane-args ()
  "カレントバッファの `zellij-send--pane-id' から --pane-id 引数リストを返す。
pane-id 不明なら nil（focused pane への送信になる）。"
  (when zellij-send--pane-id
    (list "--pane-id" zellij-send--pane-id)))

(defun zellij-send--send (session text &optional callback)
  "SESSION に TEXT を送り、続けて Enter キー（0x0D）を非同期送信する。
カレントバッファに `zellij-send--pane-id' があればそのペインへ、
なければ focused pane へ送る（後者は attach クライアントが必要）。
完了したら CALLBACK に成功なら t、失敗なら nil を渡して呼ぶ（省略可）。
失敗時はメッセージも表示する。

本文は `write-chars' ではなく `paste'（bracketed paste）で送る。
`write-chars' は改行を LF のまま渡すため、LF で入力を確定する受け手
（シェルなど）だと複数行テキストが行ごとに実行されてしまう。
`paste' は受け手が bracketed paste を有効にしている時だけマーカーで
包むので、対応していないペインへ送っても余計な文字は現れない。"
  (let ((pane-args (zellij-send--pane-args)))
    (zellij-send--zellij-async
     (append (list "--session" session "action" "paste")
             pane-args (list "--" text))
     (lambda (exit1)
       (if (not (zerop exit1))
           (progn
             (message "zellij テキスト送信失敗 (exit: %d)" exit1)
             (when callback (funcall callback nil)))
         (zellij-send--zellij-async
          (append (list "--session" session "action" "write")
                  pane-args (list "--" "13"))
          (lambda (exit2)
            (if (not (zerop exit2))
                (progn
                  (message "zellij Enter 送信失敗 (exit: %d)" exit2)
                  (when callback (funcall callback nil)))
              (when callback (funcall callback t))))))))))

(defun zellij-send--send-keys (session bytes &optional callback)
  "SESSION の対象ペインに BYTES（数値のリスト）をキー入力として送る。
カレントバッファの `zellij-send--pane-id' を使うので、必ず対象バッファを
カレントにして呼ぶこと。テキストではなく制御文字を送るための入口
（例: Esc = 27）。"
  (zellij-send--zellij-async
   (append (list "--session" session "action" "write")
           (zellij-send--pane-args)
           (list "--")
           (mapcar #'number-to-string bytes))
   callback))

;;; スクリーンダンプ

(defun zellij-send--strip-ansi (str)
  "STR から ANSI エスケープシーケンスを除去して返す。

`list-sessions' の出力には今もカラーコードが入るので、この関数は現役。
`dump-screen' の方は zellij が既に平文で返すため保険（`--ansi' 指定時のみ
エスケープが残る）。

除去の順序が重要。文字列終端まで舐める OSC / DCS を先に処理しないと、
最後の 2 文字エスケープ規則が `ESC ]' の 2 文字だけを食って
`0;title' とベル文字が本文に残る。同じ理由で、3 バイト以上になる
nF エスケープ（`ESC ( B' など）も 2 文字規則より前に処理する。"
  (let ((result str))
    ;; OSC: ESC ] ... BEL または ESC ] ... ST(ESC \)
    (setq result (replace-regexp-in-string
                  "\033\\][^\a\033]*\\(?:\a\\|\033\\\\\\)" "" result))
    ;; DCS / SOS / PM / APC: ESC P|X|^|_ ... ST(ESC \)
    (setq result (replace-regexp-in-string
                  "\033[PX^_][^\033]*\033\\\\" "" result))
    ;; CSI: ESC [ ... 英字
    (setq result (replace-regexp-in-string "\033\\[[0-9;?]*[A-Za-z]" "" result))
    ;; nF エスケープ: ESC + 中間バイト(0x20-0x2F)+ + 最終バイト(0x30-0x7E)。
    ;; ESC ( B は 3 バイトなので、下の 2 文字規則だけだと `B' が本文に残る
    (setq result (replace-regexp-in-string "\033[ -/]+[0-~]" "" result))
    ;; その他の 2 文字エスケープ（ESC =、ESC 7、ESC M など）
    (setq result (replace-regexp-in-string "\033." "" result))
    result))

(defun zellij-send--process-dump (raw)
  "dump-screen / subscribe の生テキスト RAW を整形して返す。
zellij は `--ansi' を付けない限りエスケープを除去済みの平文を返すので、
`zellij-send--strip-ansi' はここでは保険として通しているだけ。

**行末の空白を必ず削る**。`subscribe' の `viewport' は各行をペイン幅ぶん
スペースで右パディングして返す（`dump-screen' は返さない）ので、320 桁に
広げた背景セッションでは 1 行あたり数百文字の空白が付いてくる（2026-07-29 実測）。
末尾の連続空行もまとめて落とす。ANSI 除去より後に行うこと
（エスケープが残ったままだと行末を正しく判定できない）。"
  (let* ((text (replace-regexp-in-string
                "^─+" ""
                (zellij-send--strip-ansi
                 (replace-regexp-in-string "\r" "" raw))))
         (text (replace-regexp-in-string "[ \t]+$" "" text)))
    ;; 画面下端の空行（パディングだけの行）を落とす
    (replace-regexp-in-string "\n+\\'" "" text)))

(defun zellij-send--dump-screen-async (session callback &optional full)
  "SESSION のスクリーン内容を非同期で取得する（STDOUT 直読み・zellij 0.44+）。
カレントバッファに `zellij-send--pane-id' があればそのペインをダンプする。
取得できたら整形済み文字列を、失敗時は nil を引数にして CALLBACK を呼ぶ。
CALLBACK は要求元バッファをカレントにした状態で呼ばれる。

FULL が非 nil なら `--full' を付けてスクロールバックまで取る。
**Claude Code には効かない**。alt-screen の TUI には仕様上スクロールバックが
無いため、`--full' でも viewport と同じ内容しか返らない（2026-07-28 実測）。
alt-screen でないコマンドを `zellij-send-default-command' に設定した場合の
ためだけに付けている。流れて消えた Claude の出力は
`zellij-send-log-file'（Stop フックが transcript から追記）で読む。"
  (let ((req-buffer (current-buffer))
        (out-buf (generate-new-buffer " *zellij-dump*"))
        (err-buf (generate-new-buffer " *zellij-dump-err*")))
    (make-process
     :name "zellij-dump"
     :buffer out-buf
     :stderr err-buf
     :noquery t
     :command (append (list zellij-send-executable
                            "--session" session
                            "action" "dump-screen")
                      (when full (list "--full"))
                      (when zellij-send--pane-id
                        (list "--pane-id" zellij-send--pane-id)))
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((content
                (when (zerop (process-exit-status proc))
                  (zellij-send--process-dump
                   (with-current-buffer out-buf (buffer-string))))))
           (ignore-errors (kill-buffer out-buf))
           (ignore-errors (kill-buffer err-buf))
           (when (buffer-live-p req-buffer)
             (with-current-buffer req-buffer
               (funcall callback content)))))))))

;;; transcript（Claude Code の会話履歴）

;; 画面（dump-screen / subscribe）から過去の会話は取れない。alt-screen には
;; スクロールバックが無く、送信した長文は `[Pasted text #1 +59 lines]' に
;; 畳まれて本文が画面に存在しないため。履歴は Claude Code が書く JSONL から読む。

(defun zellij-send--transcript-slug (dir)
  "作業ディレクトリ DIR に対応する Claude Code のプロジェクト名を返す。
英数字以外はすべて `-' に置き換わる（`/Users/mck/.claude' なら
`-Users-mck--claude'。2026-08-02 に実在するディレクトリ名で確認）。"
  (replace-regexp-in-string
   "[^A-Za-z0-9]" "-" (directory-file-name (expand-file-name dir))))

(defun zellij-send--transcript-file (dir)
  "DIR に対応する transcript のうち最終更新が最も新しいものを返す。無ければ nil。
同じディレクトリで複数のセッションを動かしていると取り違えうるが、
Stop フックは transcript のパスを Emacs に渡していないので現状はこれで選ぶ。"
  (let ((proj (expand-file-name (zellij-send--transcript-slug dir)
                                zellij-send-transcript-dir)))
    (when (file-directory-p proj)
      (car (sort (directory-files proj t "\\.jsonl\\'")
                 (lambda (a b)
                   (time-less-p (file-attribute-modification-time
                                 (file-attributes b))
                                (file-attribute-modification-time
                                 (file-attributes a)))))))))

(defun zellij-send--transcript-claude-p ()
  "`zellij-send-default-command' が Claude Code なら non-nil。"
  (let ((cmd (car (split-string (or zellij-send-default-command "") nil t))))
    (and cmd (string-prefix-p "claude" (file-name-nondirectory cmd)))))

(defun zellij-send--transcript-time (entry)
  "ENTRY の timestamp を `MM-DD HH:MM:SS' に整形する。読めなければ空文字。"
  (let ((ts (alist-get 'timestamp entry)))
    (or (and (stringp ts)
             (ignore-errors
               (format-time-string "%m-%d %H:%M:%S"
                                   (parse-iso8601-time-string ts))))
        "")))

(defun zellij-send--transcript-size (bytes)
  "BYTES を人が読める大きさの文字列にする。"
  (cond ((>= bytes 1048576) (format "%.1f MB" (/ bytes 1048576.0)))
        ((>= bytes 1024)    (format "%.0f KB" (/ bytes 1024.0)))
        (t                  (format "%d B" bytes))))

(defun zellij-send--transcript-block (b)
  "text を持たない会話ブロック B を 1 行の要約にする。
画像は base64 が数 MB の 1 行になり、そのまま出すと黒板が読めなくなるので
必ず要約に置き換える（元データは表示しても意味がない）。"
  (let* ((alist (and (listp b) (listp (car-safe b)) b))
         (type (and alist (alist-get 'type alist))))
    (if (not (equal type "image"))
        (format "%S" b)
      (let* ((src (alist-get 'source alist))
             (data (or (alist-get 'data src) ""))
             (media (or (alist-get 'media_type src)
                        (alist-get 'url src)
                        "image"))
             ;; base64 は元データの約 4/3 の長さ
             (bytes (/ (* 3 (length data)) 4)))
        (if (string-empty-p data)
            (format "[画像 %s]" media)
          (format "[画像 %s %s]" media
                  (zellij-send--transcript-size bytes)))))))

(defun zellij-send--transcript-text (content)
  "tool_result の CONTENT（文字列またはブロックの配列）を文字列にする。"
  (cond
   ((stringp content) content)
   ((listp content)
    (mapconcat (lambda (b)
                 (or (and (listp b) (alist-get 'text b))
                     (zellij-send--transcript-block b)))
               content "\n"))
   (t (format "%S" content))))

(defun zellij-send--transcript-entries (text)
  "transcript の TEXT（JSONL）から会話の要素を順に取り出す。
返り値は plist のリスト（`:role' `:time' `:kind' `:name' `:body' `:sub'）。
会話でない行（mode・ai-title・file-history-snapshot など）は捨てる。
壊れた行は黙って読み飛ばす（書き込み中の末尾行がありうるため）。"
  (let (out)
    (dolist (line (split-string text "\n" t))
      (let ((obj (ignore-errors
                   (json-parse-string line :object-type 'alist
                                      :array-type 'list
                                      :null-object nil
                                      :false-object nil))))
        (when obj
          (let ((type (alist-get 'type obj)))
            (when (member type '("user" "assistant"))
              (let* ((time (zellij-send--transcript-time obj))
                     (sub (and (alist-get 'isSidechain obj) t))
                     (content (alist-get 'content (alist-get 'message obj)))
                     (base (list :role type :time time :sub sub)))
                (if (stringp content)
                    (push (append base (list :kind "text" :body content)) out)
                  (dolist (b content)
                    (let ((kind (alist-get 'type b)))
                      (push
                       (append
                        base
                        (cond
                         ((equal kind "text")
                          (list :kind "text" :body (alist-get 'text b)))
                         ((equal kind "thinking")
                          (list :kind "thinking" :body (alist-get 'thinking b)))
                         ((equal kind "tool_use")
                          (list :kind "tool_use"
                                :name (alist-get 'name b)
                                :body (json-encode (alist-get 'input b))))
                         ((equal kind "tool_result")
                          (list :kind "tool_result"
                                :name (and (alist-get 'is_error b) "エラー")
                                :body (zellij-send--transcript-text
                                       (alist-get 'content b))))
                         (t (list :kind (or kind "?")
                                  :body (zellij-send--transcript-block b)))))
                       out))))))))))
    (nreverse out)))

(defun zellij-send--transcript-clip (body)
  "BODY の各行を `zellij-send-transcript-max-line-length' 文字までに切る。
行数ではなく 1 行の長さを見る。base64 や JSON は改行を持たないので、
行数で切っても画面が埋まるのを止められないため。"
  (let ((max zellij-send-transcript-max-line-length))
    (if (not (and max (natnump max) (> max 0)))
        body
      (mapconcat
       (lambda (line)
         (if (<= (length line) max)
             line
           (concat (substring line 0 max)
                   (format "…（この行はあと %d 文字）" (- (length line) max)))))
       (split-string (or body "") "\n")
       "\n"))))

(defun zellij-send--transcript-trim (body)
  "BODY を読める大きさに切り詰める。
長すぎる行を `zellij-send--transcript-clip' で切ってから、
`zellij-send-transcript-max-block-lines' 行までに縮める。
行を先に切るのは、長い 1 行は行数制限では止まらないため。"
  (let ((body (zellij-send--transcript-clip body))
        (max zellij-send-transcript-max-block-lines))
    (if (not (and max (natnump max)))
        body
      (let ((lines (split-string (or body "") "\n")))
        (if (<= (length lines) max)
            body
          (concat (string-join (seq-take lines max) "\n")
                  (format "\n… （残り %d 行）" (- (length lines) max))))))))

(defun zellij-send--transcript-format (entries)
  "ENTRIES を黒板に流す文字列に整形する。
役割が変わるたびに `## ' 見出しを置き、text 以外のブロックには
`### ' の小見出しを付ける。"
  (let (out (prev nil))
    (dolist (e entries)
      (let* ((role (plist-get e :role))
             (kind (plist-get e :kind))
             (name (plist-get e :name))
             ;; tool_result は role が "user" だが、あなたの発言ではないので分ける
             (head (concat (if (equal kind "tool_result") "tool" role)
                           (if (plist-get e :sub) "（サブ）" ""))))
        (unless (equal head prev)
          (setq prev head)
          (push (format "\n## %s  %s" head (plist-get e :time)) out))
        (unless (equal kind "text")
          (push (format "### %s%s" kind (if name (format "  %s" name) "")) out))
        (push (zellij-send--transcript-trim
               (string-trim (or (plist-get e :body) "")))
              out)))
    (string-trim (string-join (nreverse out) "\n"))))

(defun zellij-send--transcript-show (file)
  "FILE（transcript）の会話を黒板バッファに流す。
`zellij-send--update-buffer' は使わない。あれはプロンプト検出と
AskUserQuestion の自動起動を伴うので、過去の会話文で誤爆する。"
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (body (zellij-send--transcript-format
                (zellij-send--transcript-entries text))))
    (if (string-empty-p body)
        (message "transcript に会話がありません: %s" file)
      (with-silent-modifications
        (erase-buffer)
        (insert body))
      (set-buffer-modified-p nil)
      ;; 自動更新に上書きされないよう、クリアと同じ扱いにする
      (setq zellij-send--user-cleared t)
      (zellij-send--clear-prompt-highlight)
      (goto-char (point-max))
      (let ((win (get-buffer-window (current-buffer) t)))
        (when (window-live-p win) (set-window-point win (point-max))))
      (message "会話履歴を表示しました（%s）。生画面に戻すには C-c C-a → g"
               (file-name-nondirectory file)))))

;;; セッション情報の取得（cwd・pane-id）

(defun zellij-send--zellij-output-async (session args callback)
  "SESSION に対して zellij を ARGS で実行し、STDOUT を CALLBACK に渡す。
失敗時は nil を渡す。"
  (let ((out-buf (generate-new-buffer " *zellij-out*"))
        (err-buf (generate-new-buffer " *zellij-out-err*")))
    (make-process
     :name "zellij-output"
     :buffer out-buf
     :stderr err-buf
     :noquery t
     :command (append (list zellij-send-executable "--session" session) args)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((out (and (zerop (process-exit-status proc))
                         (with-current-buffer out-buf (buffer-string)))))
           (ignore-errors (kill-buffer out-buf))
           (ignore-errors (kill-buffer err-buf))
           (funcall callback out)))))))

(defun zellij-send--parse-panes (raw)
  "`action list-panes' の出力 RAW から端末ペインの (ID . TITLE) を順に返す。
出力は「PANE_ID  TYPE  TITLE」の表。plugin ペインは除外する。"
  (delq nil
        (mapcar
         (lambda (line)
           (let ((clean (string-trim (zellij-send--strip-ansi line))))
             (when (string-match "\\`\\(terminal_[0-9]+\\)[ \t]+terminal[ \t]*\\(.*\\)\\'"
                                 clean)
               (cons (match-string 1 clean)
                     (string-trim (match-string 2 clean))))))
         (split-string raw "\n" t))))

(defun zellij-send--pick-pane (panes)
  "PANES（(ID . TITLE) のリスト）から送信先として最も妥当なものを選ぶ。
`zellij-send-default-command' と同名のタイトルを優先し、
無ければ最初の端末ペインを使う。"
  (or (car (seq-find (lambda (p)
                       (string= (cdr p) zellij-send-default-command))
                     panes))
      (caar panes)))

(defun zellij-send--detect-pane-async (session callback)
  "SESSION の送信先 pane-id を推定して CALLBACK に渡す（不明なら nil）。"
  (zellij-send--zellij-output-async
   session '("action" "list-panes")
   (lambda (out)
     (funcall callback
              (and out (zellij-send--pick-pane
                        (zellij-send--parse-panes out)))))))

(defun zellij-send--parse-layout-cwd (raw)
  "`action dump-layout' の出力 RAW からセッションの cwd を返す（無ければ nil）。"
  (when (string-match "^[[:space:]]*cwd[[:space:]]+\"\\([^\"]+\\)\"" raw)
    (match-string 1 raw)))

(defun zellij-send--session-cwd-async (session callback)
  "SESSION の作業ディレクトリを CALLBACK に渡す（不明なら nil）。"
  (zellij-send--zellij-output-async
   session '("action" "dump-layout")
   (lambda (out)
     (funcall callback (and out (zellij-send--parse-layout-cwd out))))))

(defun zellij-send-attach-session-async (session &optional callback)
  "既存の SESSION 用バッファを、ユーザーに何も聞かずに用意する。
cwd は `dump-layout'、pane-id は `list-panes' から取得して設定する。
pane-id が取れれば attach クライアント無しでも送信できる。
用意できたら CALLBACK にバッファを渡す。"
  (let ((buf (zellij-send--get-or-create-buffer session)))
    (zellij-send--session-cwd-async
     session
     (lambda (cwd)
       (when (and cwd (buffer-live-p buf) (file-directory-p cwd))
         (with-current-buffer buf
           (setq-local default-directory (file-name-as-directory cwd))))
       (zellij-send--detect-pane-async
        session
        (lambda (pane-id)
          (when (and pane-id (buffer-live-p buf))
            (with-current-buffer buf
              (setq-local zellij-send--pane-id pane-id)
              (zellij-send--subscribe-ensure)))
          (when callback (funcall callback buf))))))))

;;; 送信履歴

;; 履歴はセッション名をキーにしたグローバル表に持つ。黒板バッファと
;; 返信バッファで同じ履歴を共有し、バッファを閉じても残るため。
;; 辿っている位置と下書きの退避はバッファローカル。

(defvar zellij-send--history-table (make-hash-table :test #'equal)
  "セッション名 -> 送信済みテキストのリスト（新しい順）。")

(defvar-local zellij-send--history-index nil
  "履歴を辿っている位置（0 が最新）。nil なら辿っていない。")

(defvar-local zellij-send--history-draft nil
  "履歴を辿り始める前のバッファ内容。")

(defun zellij-send-history (session)
  "SESSION の送信履歴（新しい順）を返す。"
  (gethash session zellij-send--history-table))

(defun zellij-send--history-add (session text)
  "SESSION の履歴に TEXT を追加する。直前と同じ内容なら追加しない。"
  (let ((history (zellij-send-history session)))
    (unless (equal (car history) text)
      (setq history (cons text history))
      (when (> (length history) zellij-send-history-max)
        (setq history (seq-take history zellij-send-history-max)))
      (puthash session history zellij-send--history-table))))

(defun zellij-send--history-replace (text)
  "バッファの内容を TEXT で置き換える。
ポーリングに上書きされないよう、変更済みのままにしておく。"
  (erase-buffer)
  (insert text)
  (goto-char (point-max)))

(defun zellij-send--history-move (delta)
  "履歴を DELTA 分だけ辿ってバッファに出す。DELTA が正なら古い方へ。"
  (zellij-send--assert-session)
  (let* ((history (zellij-send-history zellij-send--session))
         (index (+ (or zellij-send--history-index -1) delta)))
    (unless history
      (user-error "送信履歴がありません"))
    (cond
     ((< index 0)
      ;; 最新より新しい側に戻ったら、辿り始める前の下書きに復帰する
      (setq zellij-send--history-index nil)
      (zellij-send--history-replace (or zellij-send--history-draft ""))
      (setq zellij-send--history-draft nil)
      (message "下書きに戻りました"))
     ((>= index (length history))
      (user-error "これ以上古い履歴はありません"))
     (t
      (when (null zellij-send--history-index)
        (setq zellij-send--history-draft (buffer-string)))
      (setq zellij-send--history-index index)
      (zellij-send--history-replace (nth index history))
      (message "履歴 %d/%d" (1+ index) (length history))))))

(defun zellij-send-history-prev ()
  "1 つ前に送信したテキストを呼び戻す。"
  (interactive)
  (zellij-send--history-move 1))

(defun zellij-send-history-next ()
  "1 つ後に送信したテキストを呼び戻す（最新まで戻ると下書きに復帰）。"
  (interactive)
  (zellij-send--history-move -1))

(defun zellij-send-history-select ()
  "送信履歴から選んでバッファに入れる。"
  (interactive)
  (zellij-send--assert-session)
  (let ((history (zellij-send-history zellij-send--session)))
    (unless history
      (user-error "送信履歴がありません"))
    (let ((choice (completing-read "履歴: " history nil t)))
      (when (null zellij-send--history-index)
        (setq zellij-send--history-draft (buffer-string)))
      (setq zellij-send--history-index (seq-position history choice))
      (zellij-send--history-replace choice))))

;;; プロンプト検出・ハイライト

(defun zellij-send--detect-prompt ()
  "バッファに Claude Code の選択肢プロンプトがあれば non-nil を返す。"
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "❯[[:space:]]*[1-9]\\." nil t)))

(defun zellij-send--clear-prompt-highlight ()
  "選択肢行のハイライトを消す。"
  (remove-overlays (point-min) (point-max) 'zellij-send-prompt t))

(defun zellij-send--highlight-prompt ()
  "選択肢行をハイライトする。"
  (zellij-send--clear-prompt-highlight)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^.*❯[[:space:]]*[1-9]\\..*$" nil t)
      (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
        (overlay-put ov 'zellij-send-prompt t)
        (overlay-put ov 'face 'highlight)))))

;;; バッファ更新（共通処理）

(defun zellij-send--update-buffer (content)
  "バッファを CONTENT で更新し、プロンプト検出・ハイライトを実行する。
カーソル位置とウィンドウの表示開始位置は可能な範囲で復元する
（ポーリング更新のたびに読んでいる箇所が先頭へ飛ぶのを防ぐため）。"
  (let* ((win (get-buffer-window (current-buffer) t))
         (pos (point))
         (wstart (and (window-live-p win) (window-start win))))
    (with-silent-modifications
      (erase-buffer)
      (insert content))
    (goto-char (min pos (point-max)))
    (when (window-live-p win)
      (set-window-point win (point))
      (when wstart
        (set-window-start win (min wstart (point-max)) t))))
  (set-buffer-modified-p nil)
  (if (zellij-send--detect-prompt)
      (zellij-send--highlight-prompt)
    (zellij-send--clear-prompt-highlight))
  (zellij-send--askq-maybe-auto))

;;; 自動受信（zellij subscribe）

;; セッションごとに `zellij subscribe' の常駐プロセスを 1 本持ち、ペインの
;; 変化をイベントで受け取る。2 秒ごとに dump-screen のプロセスを起こす
;; ポーリングは廃止した（アイドル 20 秒でイベント 1 件に対し、ポーリングは
;; プロセス 10 個。実測）。
;;
;; 実測（zellij 0.44.3）で分かった注意点:
;; - `subscribe' は `--pane-id' が必須。pane-id 不明なら先に特定する
;; - イベントは NDJSON。viewport は差分ではなく毎回フルの行配列
;; - 1 イベント約 8 KB で複数回に分かれて届くので行単位のバッファリングが要る
;; - **セッションが消えても subscribe は終了しない**（force delete 後も
;;   17 秒以上生き続けた）。プロセスの死を検知手段にできない。バッファが
;;   kill されたときに `kill-buffer-hook' で確実に殺す
;; - 存在しないセッションを指定すると**終了コード 0 のまま**何も流れない。
;;   よって「初回イベントが来たか」で成否を判定する

(defun zellij-send--subscribe-stop ()
  "このバッファの subscribe プロセスとタイマーを止める。
意図的な停止なので sentinel を無効化してから殺す（再接続させないため）。"
  (when zellij-send--subscribe-timer
    (cancel-timer zellij-send--subscribe-timer)
    (setq zellij-send--subscribe-timer nil))
  (when zellij-send--subscribe-process
    (let ((proc zellij-send--subscribe-process))
      (setq zellij-send--subscribe-process nil)
      (set-process-sentinel proc #'ignore)
      (when (process-live-p proc)
        (delete-process proc))))
  (setq zellij-send--subscribe-pending ""))

(defun zellij-send--subscribe-handle-line (line)
  "subscribe から届いた 1 行 LINE を解釈してバッファに反映する。"
  (let ((line (string-trim line)))
    (unless (string-empty-p line)
      (let* ((obj (ignore-errors
                    (json-parse-string line :object-type 'alist
                                       :array-type 'list :null-object nil)))
             (viewport (alist-get 'viewport obj)))
        (when (listp viewport)
          (setq zellij-send--subscribe-retries 0
                zellij-send--last-event-time (float-time))
          (let ((content (zellij-send--process-dump
                          (string-join viewport "\n"))))
            ;; 変化の記録は更新抑止中も続ける（ダッシュボードが見るため）
            (unless (equal content zellij-send--last-content)
              (setq zellij-send--last-content content
                    zellij-send--last-change-time (float-time)))
            ;; 書き換えは、ユーザーが編集中でもクリア直後でもないときだけ
            (when (and (not (buffer-modified-p))
                       (not zellij-send--user-cleared)
                       (not (string= content (buffer-string))))
              (zellij-send--update-buffer content))))))))

(defun zellij-send--subscribe-filter (buf out)
  "subscribe プロセスの出力 OUT を BUF で行単位に解釈する。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq zellij-send--subscribe-pending
            (concat zellij-send--subscribe-pending out))
      (let ((lines (split-string zellij-send--subscribe-pending "\n")))
        ;; 末尾は未完の行（改行で終わっていれば空文字）。次の出力に持ち越す
        (setq zellij-send--subscribe-pending (car (last lines)))
        (dolist (line (butlast lines))
          (zellij-send--subscribe-handle-line line))))))

(defun zellij-send--subscribe-schedule-retry ()
  "subscribe を指数バックオフで張り直す。上限を超えたらあきらめる。"
  (setq zellij-send--subscribe-retries (1+ zellij-send--subscribe-retries))
  (if (> zellij-send--subscribe-retries zellij-send-subscribe-max-retries)
      (message "セッション [%s] の自動更新に %d 回失敗しました（C-c C-a → a で手動取得）"
               zellij-send--session zellij-send-subscribe-max-retries)
    (let ((delay (min zellij-send-subscribe-backoff-max
                      (expt 2.0 (1- zellij-send--subscribe-retries))))
          (buf (current-buffer)))
      (setq zellij-send--subscribe-timer
            (run-at-time delay nil
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (setq zellij-send--subscribe-timer nil)
                               (zellij-send--subscribe-ensure)))))))))

(defun zellij-send--subscribe-check-initial (buf)
  "BUF の subscribe が初回イベントを受け取れたか確認し、駄目なら張り直す。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq zellij-send--subscribe-timer nil)
      (unless zellij-send--last-event-time
        (zellij-send--subscribe-stop)
        (zellij-send--subscribe-schedule-retry)))))

(defun zellij-send--subscribe-start ()
  "このバッファの subscribe を開始する。pane-id が分かっていることが前提。"
  (zellij-send--subscribe-stop)
  (when (and zellij-send--session zellij-send--pane-id)
    (let* ((buf (current-buffer))
           (session zellij-send--session)
           (process-environment (zellij-send--process-environment)))
      (setq zellij-send--subscribe-pane-id zellij-send--pane-id
            zellij-send--last-event-time nil)
      (setq zellij-send--subscribe-process
            (make-process
             :name (format "zellij-subscribe-%s" session)
             :buffer nil
             :noquery t
             :connection-type 'pipe
             :command (list zellij-send-executable
                            "--session" session
                            "subscribe"
                            "--pane-id" zellij-send--pane-id
                            "--format" "json")
             :filter (lambda (_proc out)
                       (zellij-send--subscribe-filter buf out))
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (when (eq zellij-send--subscribe-process proc)
                       (setq zellij-send--subscribe-process nil)
                       (zellij-send--subscribe-schedule-retry))))))))
      ;; 終了コードが当てにならないので、初回イベントの有無で成否を見る
      (setq zellij-send--subscribe-timer
            (run-at-time zellij-send-subscribe-initial-timeout nil
                         #'zellij-send--subscribe-check-initial buf))
      ;; ペインに繋がったので、スラッシュコマンド一覧を先読みしておく
      (zellij-send--slash-prefetch-maybe))))

(defun zellij-send--subscribe-ensure ()
  "必要なら subscribe を（再）開始する。
既に生きていて pane-id も一致していれば何もしない。
`subscribe' は `--pane-id' 必須なので、不明なら先に特定してから張る。"
  (when (and zellij-send--session
             (not (and zellij-send--subscribe-process
                       (process-live-p zellij-send--subscribe-process)
                       (equal zellij-send--subscribe-pane-id
                              zellij-send--pane-id))))
    (if zellij-send--pane-id
        (zellij-send--subscribe-start)
      (let ((buf (current-buffer))
            (session zellij-send--session))
        (zellij-send--detect-pane-async
         session
         (lambda (pane-id)
           (when (and pane-id (buffer-live-p buf))
             (with-current-buffer buf
               (setq-local zellij-send--pane-id pane-id)
               (zellij-send--subscribe-start)))))))))

;;; Claude Code コマンド

;; `/compact' と `/clear' はメニューから外した（`zellij-send-slash-command' で
;; どのスラッシュコマンドも送れるようになったため）。M-x とダッシュボードの
;; `c'（`zellij-send-dashboard-compact')から使うのでコマンド自体は残す。

(defun zellij-send-compact ()
  "セッションに /compact を送信してコンテキストを圧縮する。
メニューには無い（`C-c C-a' → `/' か M-x、ダッシュボードの `c'）。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--send zellij-send--session "/compact"
                     (lambda (ok)
                       (when ok (message "圧縮しました")))))

(defun zellij-send-cc-clear ()
  "セッションに /clear を送信してコンテキストをリセットする。
メニューには無い（`C-c C-a' → `/' か M-x）。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--send zellij-send--session "/clear"
                     (lambda (ok)
                       (when ok (message "クリアしました（コンテキスト）")))))

(defun zellij-send-interrupt ()
  "実行中の処理を中断する（対象ペインに Esc を送る）。
状態は問わない。ダッシュボードの状態表示は数秒古いことがあり、
「作業中に見えない」ことを理由に中断を拒むと止められなくなるため。"
  (interactive)
  (zellij-send--assert-session)
  (let ((session zellij-send--session))
    (zellij-send--send-keys
     session '(27)
     (lambda (exit)
       (if (zerop exit)
           (message "中断しました → [%s]" session)
         (message "中断の送信に失敗しました (exit: %d)" exit))))))

(defun zellij-send-save-progress ()
  "現在の作業内容を CLAUDE.md に記録するよう依頼する。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--send zellij-send--session
                     "ここまでの作業内容と決定事項を CLAUDE.md に追記して"
                     (lambda (ok)
                       (when ok (message "記録を依頼しました")))))

;;; スラッシュコマンド（Claude Code の /コマンド全部）

;; 2026-07-29 に Claude Code v2.1.220 + zellij 0.44.3（320 桁の背景セッション）で
;; 実測した補完メニューの仕様。**同じ調査を繰り返さないこと。**
;;
;;   /doctor            Health-check the user's Claude Code setup and fix issues: …
;;                      MCP servers, and plugins versus their context cost and …   ← 折り返し
;;   /ndl               国立国会図書館(NDL)のデジタルコレクション…  (user)
;;   ────────────────────────────────────────────────────────────── ↯ ─   ← 入力枠の上罫線
;;   ❯ /
;;   ──────────────────────────────────────────────────────────────
;;
;; - 一覧は入力欄に `/` を打つと**入力枠のすぐ上**に出る。1 件 `  /name  説明`。
;;   説明は折り返して深いインデントの続き行になる
;; - **メニューは 4 行しか出ない**。説明が折り返すと 2 件しか見えないので、
;;   全件（実測 102 件）を得るには ↓ を送りながら読み続けるしかない。
;;   ここだけは往復が要るので、一度取ったらバッファに覚える（C-u で取り直し）
;; - ↓ はカーソルを 1 件動かす。**カーソルが最下段に来て初めて窓が 1 件ずつ動く**。
;;   つまり定常状態では「見えている件数 - 1」回の ↓ で 1 件重なりを残して送れる。
;;   一括で大きく飛ばすと取りこぼすので、必ず見えている件数から毎回決めること
;; - `/name ` まで打つと**引数のヒントがゴースト表示**される
;;   （`/model  [model]`、`/effort  [low|medium|high|xhigh|max|ultracode|auto]`）。
;;   引数を取らないコマンドは末尾の空白ごと消えて `/name` のまま。これが
;;   「引数が要るか」の唯一の判定材料
;; - 入力欄は **Ctrl+U（21）で消す。Esc では消えない**（実測。Esc を送っても
;;   `/c` が残り、続けて `/` を打つと `/c/` になってメニューが出なくなった）
;; - `paste` で送ったテキストは補完メニューを開かない。`/effort high` を paste して
;;   Enter でそのまま実行できる（既存の `zellij-send--send' がそのまま使える）
;;
;; ペインの入力欄を実際に打って調べるので、**入力欄が空でないときは何もしない**。
;; ユーザーがターミナル側で書きかけたテキストを Ctrl+U で消してしまわないため。

(defcustom zellij-send-slash-settle-delay 0.25
  "スラッシュコマンドの操作で、キーを送ってから画面を読み直すまでの待ち時間（秒）。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-slash-max-rounds 200
  "コマンド一覧を集めるときにメニューを送る回数の上限。
実測 102 件を 1 回 3 件前後で送るので通常は 40 回程度で終わる。
画面を読み違えて空回りしても必ず止まるための歯止め。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-slash-arg-max-rounds 40
  "引数の候補メニューを集めるときに ↓ を送る回数の上限。
`/plugin install' のように候補が数百あるコマンドで延々とキーを送り続けない
ための歯止め。ここで打ち切った一覧は「一部」として扱い、キャッシュしない
（欠けた一覧を焼き付けると以後ずっと欠けたまま出る）。候補に無い値も
そのまま打てるので、打ち切っても行き止まりにはならない。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-slash-prefetch t
  "non-nil なら、黒板バッファを開いた少し後に一覧を黙って取りに行く。
初回の `zellij-send-slash-command' を待ち時間ゼロにするための先読み。
取得はペインに実際にキーを送るので、ペインを一切触られたくない環境では
nil にする。"
  :type 'boolean
  :group 'zellij-send)

(defcustom zellij-send-slash-prefetch-delay 5
  "先読みを始めるまでの待ち時間（秒）。
起動直後の claude はまだ入力を受け付けないことがあるので少し置く。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-slash-prefetch-retries 4
  "先読みをやり直す回数の上限。
信頼確認（trust プロンプト）などで入力欄が空でないときは取得を諦めるので、
少し置いて何度か試す。使い切ったら諦めて、初回の
`zellij-send-slash-command' で取ることになる。"
  :type 'integer
  :group 'zellij-send)

(defvar zellij-send--slash-cache-table (make-hash-table :test 'equal)
  "作業ディレクトリごとのスラッシュコマンド一覧。
キーは絶対パス、値は ((\"/name\" . \"説明\") ...)。
**セッションではなくディレクトリで持つ**——一覧の中身を決めるのは
プロジェクトのコマンドとスキルなので、同じディレクトリのセッションなら
同じ結果になる。2 つ目以降のセッションは取得ゼロで開ける。")

(defvar-local zellij-send--slash-prefetching nil
  "先読みの取得中なら non-nil。多重起動を防ぎ、進捗メッセージを黙らせる。")

(defun zellij-send--slash-cache-key ()
  "カレントバッファのスラッシュコマンド一覧のキー（作業ディレクトリ）を返す。"
  (directory-file-name (file-truename default-directory)))

(defun zellij-send--slash-cached ()
  "カレントバッファのディレクトリの一覧を返す。無ければ nil。"
  (gethash (zellij-send--slash-cache-key) zellij-send--slash-cache-table))

(defun zellij-send--slash-cache-put (alist)
  "ALIST をカレントバッファのディレクトリの一覧として覚える。"
  (puthash (zellij-send--slash-cache-key) alist zellij-send--slash-cache-table))

(defvar zellij-send--slash-arg-cache-table (make-hash-table :test 'equal)
  "引数の候補メニューのキャッシュ。
キーは (ディレクトリ コマンド ここまでの引数)、値は ((候補 . 説明) ...)。
`/plugin install' のように候補が数百あるものを毎回集め直さないため。
**打ち切った（一部の）一覧は入れない**。`C-u' で捨てる。")

(defun zellij-send--slash-arg-cache-key (name args open)
  "NAME・ARGS（OPEN は末尾が書きかけか）の引数候補キャッシュのキーを返す。"
  (list (zellij-send--slash-cache-key) name (string-trim (or args "")) (and open t)))

(defun zellij-send--slash-arg-cached (name args open)
  "NAME・ARGS の引数候補を覚えていれば返す。無ければ nil。"
  (gethash (zellij-send--slash-arg-cache-key name args open)
           zellij-send--slash-arg-cache-table))

(defun zellij-send--slash-arg-cache-put (name args open entries)
  "NAME・ARGS の引数候補として ENTRIES を覚える。"
  (when entries
    (puthash (zellij-send--slash-arg-cache-key name args open) entries
             zellij-send--slash-arg-cache-table)))

(defun zellij-send--slash-arg-cache-clear ()
  "カレントバッファのディレクトリぶんの引数候補キャッシュを捨てる。
`maphash' の最中に消すと動作が保証されないので、キーを集めてから消す。"
  (let ((dir (zellij-send--slash-cache-key))
        (keys nil))
    (maphash (lambda (k _v) (when (equal (car k) dir) (push k keys)))
             zellij-send--slash-arg-cache-table)
    (dolist (k keys) (remhash k zellij-send--slash-arg-cache-table))))

(defun zellij-send--slash-msg (format-string &rest args)
  "先読み中でなければ `message' する。先読みは黙って走らせる。"
  (unless zellij-send--slash-prefetching
    (apply #'message format-string args)))

(defconst zellij-send--slash-input-regexp "\\`❯[[:space:]]?\\(.*\\)\\'"
  "入力欄の行に一致する正規表現。1=入力欄の中身。")

(defconst zellij-send--slash-entry-regexp
  "\\`[[:space:]]+\\(/[A-Za-z0-9:_-]+\\)\\(?:[[:space:]]\\{2,\\}\\(.*\\)\\)?\\'"
  "補完メニューの 1 件に一致する正規表現。1=コマンド名 2=説明。")

(defconst zellij-send--slash-arg-entry-regexp
  "\\`[[:space:]]\\{1,6\\}\\([A-Za-z0-9._~][^[:space:]]\\{0,120\\}\\)\\(?:[[:space:]]\\{2,\\}\\(.*\\)\\)?\\'"
  "引数の候補メニューの 1 件に一致する正規表現。1=候補 2=説明。
コマンド一覧と同じ場所に出るが**先頭に `/' が付かない**
（`autoScroll=' / `enable' / `Documents/'。2026-09-06 実測）。
本文の行を拾わないよう、候補は空白を含まない 1 語に限り、
`/' 始まり（＝コマンド一覧）と記号始まり（`⏺' などの本文の飾り）を除く。")

(defconst zellij-send--slash-arg-max-visible 8
  "1 画面から拾う引数候補の上限。
メニューは実測 5 件までなので、これを超えたら本文を読み違えている。")

(defconst zellij-send--slash-hint-regexp
  "\\`\\(/[A-Za-z0-9:_-]+\\)[[:space:]]+\\(?:\\[\\(.*\\)\\]\\|<\\(.*\\)>\\)\\'"
  "入力欄に出る引数ヒントに一致する正規表現。1=コマンド名 2/3=ヒント。
角括弧（`/effort  [low|medium|…]'）と山括弧（`/add-dir  <path>'）の
両方が使われる（実測）。片方だけを見ると `/add-dir' のような
コマンドを「引数なし」と誤判定する。")

(defun zellij-send--slash-border-p (line)
  "LINE が入力枠の罫線（またはその残骸）なら non-nil。
`zellij-send--process-dump' が行頭の ─ を削るので、罫線は
\" ↯ ─\" のような短い残骸になって残る。"
  (string-match-p "\\`[[:space:]↯─]*\\'" line))

(defun zellij-send--slash-input-text (screen)
  "SCREEN の入力欄の中身を返す。入力欄が見つからなければ nil。
一番下の ❯ 行を入力欄とみなす。"
  (let* ((lines (split-string screen "\n"))
         (i (zellij-send--askq-last-index lines zellij-send--slash-input-regexp)))
    (when i
      (let ((line (nth i lines)))
        (string-match zellij-send--slash-input-regexp line)
        (string-trim-right (match-string 1 line))))))

(defun zellij-send--slash-idle-p (screen)
  "SCREEN の入力欄が空（入力を受け付けられる状態）なら non-nil。
プレースホルダ（`Try \"...\"'）は空とみなす。選択肢プロンプトが出ている間は
矢印キーがそちらに効いてしまうので `zellij-send--askq-parse' で弾く。"
  (let ((text (zellij-send--slash-input-text screen)))
    (and text
         (null (zellij-send--askq-parse screen))
         (or (string-empty-p text)
             (string-prefix-p "Try \"" text)))))

(defun zellij-send--slash-menu-block (screen regexp &optional limit)
  "SCREEN の入力枠のすぐ上のメニューを REGEXP で読み、((値 . 説明) ...) を返す。
LIMIT が non-nil ならその件数を読んだところでやめる。
説明の折り返し行（深いインデントの続き行）は読み飛ばす。"
  (let* ((lines (split-string screen "\n"))
         (i (zellij-send--askq-last-index lines zellij-send--slash-input-regexp))
         (entries nil))
    (when i
      (let ((j (1- i))
            (skipped 0)
            (stop nil))
        ;; 入力枠の上罫線は高々 2 行だけ読み飛ばす。空行をいくらでも跨ぐと
        ;; メニューではない本文まで拾ってしまう
        (while (and (>= j 0) (< skipped 2)
                    (zellij-send--slash-border-p (nth j lines)))
          (setq j (1- j) skipped (1+ skipped)))
        (while (and (>= j 0) (not stop))
          (let ((line (nth j lines)))
            (cond
             ((string-match regexp line)
              (push (cons (match-string 1 line)
                          (let ((desc (match-string 2 line)))
                            (and desc (string-trim desc))))
                    entries)
              (when (and limit (>= (length entries) limit))
                (setq stop t)))
             ;; 説明の折り返し（深いインデントの続き行）
             ((string-match-p "\\`[[:space:]]\\{8,\\}[^[:space:]]" line) nil)
             (t (setq stop t))))
          (setq j (1- j)))))
    entries))

(defun zellij-send--slash-menu-entries (screen)
  "SCREEN の補完メニューから ((\"/name\" . \"説明\") ...) を上から順に返す。"
  (zellij-send--slash-menu-block screen zellij-send--slash-entry-regexp))

(defun zellij-send--slash-arg-entries (screen)
  "SCREEN の引数候補メニューから ((\"値\" . \"説明\") ...) を上から順に返す。
コマンド一覧と同じ場所に出るが、行の形が違う（先頭に `/' が付かない）。"
  (zellij-send--slash-menu-block screen zellij-send--slash-arg-entry-regexp
                                 zellij-send--slash-arg-max-visible))

(defun zellij-send--slash-arg-hint (screen name)
  "SCREEN の入力欄から NAME の引数ヒント（角括弧の中身）を返す。無ければ nil。"
  (let ((text (zellij-send--slash-input-text screen)))
    (when (and text
               (string-match zellij-send--slash-hint-regexp text)
               (equal (match-string 1 text) name))
      (or (match-string 2 text) (match-string 3 text)))))

(defun zellij-send--slash-hint-kind (hint)
  "HINT がパスを求めていれば `directory' か `file'、そうでなければ nil。
`/add-dir  <path>' の類はペインに聞き返すより Emacs 側で補完した方が早い
（ペインの候補は途中まで打たないと出てこない。2026-09-06 実測）。"
  (let ((h (downcase (string-trim (or hint "")))))
    (cond
     ((member h '("path" "dir" "directory" "folder")) 'directory)
     ((member h '("file" "filename" "filepath")) 'file))))

(defun zellij-send--slash-hint-values (hint)
  "HINT から選択肢のリストを返す。選択肢の形でなければ nil。

`low|medium|high' のような素直な形だけではない。claude 本体の
argumentHint を調べると `[codex|gemini] [--dry-run]' や
`[reconnect <server>|enable|disable [<server>|all]]' のように
グループが 2 つあったり入れ子になったりする。`|' で切ってから
`<...>'（自由入力）と括弧の残骸を落とし、1 語で残ったものだけを候補にする。
候補に無い値も打てる（require-match しない）ので、落としすぎても困らない。"
  (when (and hint (string-match-p "|" hint))
    (delete-dups
     (delq nil
           (mapcar
            (lambda (piece)
              ;; グループの閉じ括弧から後ろは別のグループ（`[codex|gemini]
              ;; [--dry-run]' の `--dry-run'）なので切り落とす。残った
              ;; `<...>'（自由入力）と括弧は消す
              (let ((s (string-trim
                        (replace-regexp-in-string
                         "<[^>]*>\\|[[]" " "
                         (car (split-string piece "]"))))))
                (and (string-match-p
                      "\\`[A-Za-z0-9][A-Za-z0-9._:@/=+-]*\\'" s)
                     s)))
            (split-string hint "|" t))))))

(defun zellij-send--slash-arg-open-p (token)
  "TOKEN が書きかけ（`=' `:' `/' で終わる）なら non-nil。
`/config autoScroll=' まで打つと候補が `autoScroll=true' に変わる（実測）。
この状態では空白を足さずに続きを聞き、候補はトークンごと置き換える。"
  (and token (string-match-p "[=:/]\\'" token)))

(defun zellij-send--slash-arg-append (args value &optional replace)
  "引数文字列 ARGS に候補 VALUE を足した文字列を返す。
REPLACE が non-nil なら足さずに末尾のトークンを置き換える。
メニューの候補は**トークン全体**で返る（`autoScroll=' の次の候補は
`autoScroll=true'、`air' まで打つと `airwallex-dev@…'）ので、書きかけの
トークンに続けて選んだ候補は置き換えないと二重になる。
置き換えるかどうかは画面から推測せず、**打った側が覚えておく**
（プラグイン名が偶然そのトークンで始まることがあるため）。"
  (let ((tokens (split-string (or args "") "[[:space:]]+" t)))
    (string-join
     (if (and replace tokens)
         (append (butlast tokens) (list value))
       (append tokens (list value)))
     " ")))

(defun zellij-send--slash-probe-text (name args &optional open)
  "NAME の引数 ARGS の続きを聞くために入力欄へ打つ文字列を返す。
OPEN（末尾のトークンが書きかけ）なら空白を足さずに聞く——その状態では
メニューが打った文字で絞り込まれる。そうでなければ末尾に空白を足す
——空白を打って初めて次の候補やヒントが出る。"
  (let ((args (string-trim (or args ""))))
    (cond
     ((string-empty-p args) (concat name " "))
     ((or open (zellij-send--slash-arg-open-p args)) (concat name " " args))
     (t (concat name " " args " ")))))

;;;; ペインとのやりとり

(defun zellij-send--slash-write-chars (session text callback)
  "SESSION の対象ペインに TEXT を `write-chars' で打ち込む。
`paste' ではなく `write-chars' を使うのは補完メニューを開かせるため
（paste されたテキストではメニューが出ない。2026-07-29 実測）。
CALLBACK には成功 t / 失敗 nil を渡す。"
  (zellij-send--zellij-async
   (append (list "--session" session "action" "write-chars")
           (zellij-send--pane-args)
           (list "--" text))
   (lambda (exit) (funcall callback (zerop exit)))))

(defun zellij-send--slash-clear-input (buf callback)
  "BUF のペインの入力欄を Ctrl+U で空に戻してから CALLBACK を呼ぶ。"
  (if (not (buffer-live-p buf))
      (funcall callback nil)
    (with-current-buffer buf
      (zellij-send--send-keys zellij-send--session '(21)
                              (lambda (exit) (funcall callback (zerop exit)))))))

(defun zellij-send--slash-wait (buf pred callback &optional tries)
  "BUF のペインの画面が PRED を満たすまで待ち、その画面を CALLBACK に渡す。
待てなかったら nil を渡す。画面は毎回 `dump-screen' で取る——黒板バッファは
ユーザーが編集中だと更新が止まる（`buffer-modified-p'）ので当てにできない。"
  (let ((tries (or tries 0)))
    (if (not (buffer-live-p buf))
        (funcall callback nil)
      (with-current-buffer buf
        (zellij-send--dump-screen-async
         zellij-send--session
         (lambda (screen)
           (cond
            ((and screen (funcall pred screen)) (funcall callback screen))
            ((>= tries 12) (funcall callback nil))
            (t (run-at-time zellij-send-slash-settle-delay nil
                            #'zellij-send--slash-wait
                            buf pred callback (1+ tries))))))))))

;;;; メニューの取得（↓ で送りながら読む）

;; コマンド一覧と引数の候補は**同じ仕組み**で集める（2026-09-06 実測）。
;; 出る場所（入力枠のすぐ上）もスクロールの癖（カーソルが最下段に着いてから
;; 窓が 1 件ずつ動く・末尾で先頭へ折り返す）も同じで、違うのは行の形と、
;; メニューを開くために打つ文字列だけ。その差は SPEC の plist に閉じ込める:
;;
;;   :input      メニューを開くために入力欄へ打つ文字列（"/" や "/config "）
;;   :expect     集めている間、入力欄がこの文字列のままであること
;;   :parse      画面から ((値 . 説明) ...) を読む関数
;;   :max-rounds ↓ を送る回数の上限
;;   :sort       名前順に並べ替えるか（コマンド一覧だけ）
;;   :label      進捗メッセージに出す名前

(defun zellij-send--slash-command-spec ()
  "コマンド一覧を集めるための SPEC を返す。"
  (list :input "/" :expect "/"
        :parse #'zellij-send--slash-menu-entries
        :max-rounds zellij-send-slash-max-rounds
        :sort t
        :label "スラッシュコマンド"))

(defun zellij-send--slash-arg-spec (text)
  "引数の候補を集めるための SPEC を返す。TEXT はメニューを開く入力文字列。"
  (list :input text :expect (string-trim-right text)
        :parse #'zellij-send--slash-arg-entries
        :max-rounds zellij-send-slash-arg-max-rounds
        :sort nil
        :label "引数の候補"))

(defun zellij-send--slash-collect (buf callback)
  "BUF のセッションのスラッシュコマンド一覧を集めて CALLBACK に渡す。
失敗したら nil を渡す。"
  (zellij-send--slash-wait
   buf #'zellij-send--slash-idle-p
   (lambda (screen)
     (if (null screen)
         (progn (zellij-send--slash-msg
                 "ペインの入力欄が空ではありません。先にペインを片付けてください")
                (funcall callback nil))
       (let ((spec (zellij-send--slash-command-spec))
             (done (lambda (result) (funcall callback (plist-get result :entries)))))
         (with-current-buffer buf
           (zellij-send--slash-write-chars
            zellij-send--session (plist-get spec :input)
            (lambda (ok)
              (if (not ok)
                  (funcall callback nil)
                (zellij-send--slash-wait
                 buf (plist-get spec :parse)
                 (lambda (menu)
                   (if (null menu)
                       (zellij-send--slash-gather-finish buf spec nil nil done)
                     (zellij-send--slash-scroll
                      buf spec nil 0 0 nil nil done)))))))))))))

(defun zellij-send--slash-scroll (buf spec found rounds dry pinned last callback)
  "SPEC のメニューを ↓ で送りながら集め、集め終わったら CALLBACK に渡す。
FOUND は見つかった順の alist、ROUNDS は送った回数、DRY は画面が
進まなかった連続回数、PINNED はカーソルが最下段に着いているか、
LAST は前回見えていた値のリスト。

守るべき点が 2 つある:

- 送る ↓ の回数は**毎回、見えている件数から決める**。説明の折り返しで
  1 画面の件数が変わるので、一定量を飛ばすと静かに取りこぼす
- **画面が前回と同じ間は ↓ を送らない**。描画が追いついていないだけの
  画面を基準に次を送ると、実際の位置より先へ飛んで 1 件落ちる

一覧は最後まで行くと先頭へ折り返す。折り返した回は新顔が出ないので
DRY が伸びて止まる。**折り返しをまたぐ回だけは窓が飛ぶので最後の数件を
取りこぼす**（実測で末尾の `/verify' が落ちた）。その分は
`zellij-send--slash-tail' が ↑ の折り返しで拾う。"
  (cond
   ((not (buffer-live-p buf))
    (zellij-send--slash-gather-finish buf spec found nil callback))
   ;; 回数を使い切った。集めた分は「一部」として返す（キャッシュには入れない）
   ((> rounds (plist-get spec :max-rounds))
    (zellij-send--slash-gather-finish buf spec found t callback))
   (t
    (with-current-buffer buf
      (zellij-send--dump-screen-async
       zellij-send--session
       (lambda (screen)
         (let* ((entries (and screen (funcall (plist-get spec :parse) screen)))
                (names (mapcar #'car entries))
                (new (seq-remove (lambda (e) (assoc (car e) found)) entries))
                (found (append found new))
                (stalled (equal names last))
                ;; 新顔が出ない＝一周した。画面が動かない＝描画待ちかキーが
                ;; 効いていない。どちらも「これ以上は取れない」側に数える
                (dry (if (or stalled (null new)) (1+ dry) 0))
                (visible (length entries)))
           (cond
            ;; 入力欄が変わった＝ユーザーがターミナル側で打ち始めた。
            ;; ここで Ctrl+U を送ると相手の入力を消すので、片付けずに手を引く
            ((and screen (not (equal (zellij-send--slash-input-text screen)
                                     (plist-get spec :expect))))
             (zellij-send--slash-msg "ペインが操作されたので取得を中止しました")
             ;; 中途半端な一覧を覚えさせない。失敗として返す
             (funcall callback nil))
            ;; メニューが消えた（＝読み違えた）か、3 回続けて進まない
            ((or (null entries) (>= dry 3))
             (zellij-send--slash-tail buf spec found names callback))
            (stalled
             ;; 描画待ち。送らずにもう一度読む
             (run-at-time zellij-send-slash-settle-delay nil
                          #'zellij-send--slash-scroll
                          buf spec found (1+ rounds) dry pinned names callback))
            (t
             (when (zerop (mod rounds 8))
               (zellij-send--slash-msg "%sを取得中… %d 件"
                                       (plist-get spec :label) (length found)))
             (zellij-send--send-keys
              zellij-send--session
              ;; カーソルが最下段に着くまでは「見えている件数」、着いてからは
              ;; 「見えている件数 - 1」。後者なら 1 件重なりを残して窓が進む
              (apply #'append
                     (make-list (max 1 (if pinned (1- visible) visible))
                                '(27 91 66)))
              (lambda (exit)
                (if (not (zerop exit))
                    (zellij-send--slash-tail buf spec found names callback)
                  (run-at-time zellij-send-slash-settle-delay nil
                               #'zellij-send--slash-scroll
                               buf spec found (1+ rounds) dry t names
                               callback)))))))))))))

(defun zellij-send--slash-tail (buf spec found last callback)
  "一覧の末尾を拾ってから `zellij-send--slash-gather-finish' へ渡す。
LAST は直前に見えていた値のリスト。

メニューを開き直して先頭に戻り、そこから **↑ を 1 回**送る。一覧は先頭で
折り返すので、これで最後の 1 画面がそのまま出る（2026-07-29 実測）。
↓ で送る本編は折り返しをまたぐ回に窓が飛ぶため、末尾の数件がここでしか
取れない。"
  (zellij-send--slash-clear-input
   buf
   (lambda (_ok)
     (if (not (buffer-live-p buf))
         (zellij-send--slash-gather-finish buf spec found nil callback)
       (with-current-buffer buf
         (zellij-send--slash-write-chars
          zellij-send--session (plist-get spec :input)
          (lambda (ok)
            (if (not ok)
                (zellij-send--slash-gather-finish buf spec found nil callback)
              (zellij-send--slash-wait
               buf (plist-get spec :parse)
               (lambda (screen)
                 (zellij-send--slash-tail-up buf spec found last screen
                                             callback)))))))))))

(defun zellij-send--slash-tail-up (buf spec found last screen callback)
  "先頭に戻った SCREEN から ↑ を 1 回送り、折り返した末尾の画面を読む。"
  (if (or (null screen) (not (buffer-live-p buf)))
      (zellij-send--slash-gather-finish buf spec found nil callback)
    (let ((top (mapcar #'car (funcall (plist-get spec :parse) screen))))
      (with-current-buffer buf
        (zellij-send--send-keys
         zellij-send--session '(27 91 65)
         (lambda (exit)
           (if (not (zerop exit))
               (zellij-send--slash-gather-finish buf spec found nil callback)
             (zellij-send--slash-wait
              buf
              (lambda (s)
                (let ((names (mapcar #'car (funcall (plist-get spec :parse) s))))
                  ;; ↑ が効いた（＝画面が動いた）ことを確かめてから読む
                  (and names (not (equal names top)) (not (equal names last)))))
              (lambda (s)
                (let* ((entries (and s (funcall (plist-get spec :parse) s)))
                       (new (seq-remove (lambda (e) (assoc (car e) found)) entries)))
                  (zellij-send--slash-gather-finish
                   buf spec (append found new) nil callback)))))))))))

(defun zellij-send--slash-gather-finish (buf spec found truncated callback)
  "入力欄を片付けてから、集めた FOUND を CALLBACK に渡す。
CALLBACK に渡すのは plist (:entries ENTRIES :truncated TRUNCATED)。
TRUNCATED が non-nil なら回数を使い切って打ち切った一覧。"
  (zellij-send--slash-clear-input
   buf
   (lambda (_ok)
     (funcall callback
              (list :entries (if (plist-get spec :sort)
                                 (sort (copy-sequence found)
                                       (lambda (a b) (string< (car a) (car b))))
                               found)
                    :truncated truncated)))))

;;;; 引数を読む（ゴーストのヒントと、カーソルで選ぶ候補メニュー）

;; `/name ' まで打ったときにペインが返すものは 2 通りある（2026-09-06 実測、
;; Claude Code v2.1.263）。**同じ調査を繰り返さないこと。**
;;
;; (1) ゴーストの引数ヒント（入力欄の中に薄く出る）
;;
;;       ❯ /effort  [low|medium|high|xhigh|max|ultracode|auto]
;;       ❯ /add-dir  <path>
;;
;; (2) 候補メニュー（コマンド一覧と同じ場所・同じ操作感。カーソルで選ぶ形）
;;
;;         autoScroll=                true | false      ← /config
;;         enable          Enable an installed plugin   ← /plugin
;;         cost-optimize                                ← /claude-api（説明なし）
;;         Documents/     directory                     ← /add-dir ~/Doc
;;
;; - 出るのはどちらか片方。ヒントが出るコマンドにメニューは出ない
;; - **ヒントは引数が空のときだけ出る**（`/name ' の空白が 1 つだけの状態）。
;;   `/plugin enable ' のような深い段では出ないので、そこでは読みに行かない
;; - **候補は入れ子になる**。`/plugin ' → `enable' → `/plugin enable ' →
;;   プラグイン名、`/config ' → `autoScroll=' → `/config autoScroll=' →
;;   `autoScroll=true'。だから 1 段で終わりにせず、選ぶたびに聞き直す
;; - 候補は**トークン全体**で返る（`autoScroll=' の次は `autoScroll=true'）。
;;   足すのではなく置き換えること（`zellij-send--slash-arg-append'）
;; - メニューのスクロールはコマンド一覧と同じ。ただし `/plugin install' は
;;   候補が数百あるので `zellij-send-slash-arg-max-rounds' で打ち切る
;; - `<path>` のヒントはペインに聞かず Emacs 側で補完する。ペインの
;;   ディレクトリ候補は途中まで打たないと出てこないため

(defun zellij-send--slash-probe-arg (buf name args open callback)
  "NAME の引数 ARGS の続きをペインに聞いて CALLBACK に渡す。
CALLBACK に渡すのは plist:

  (:hint HINT)                      ゴーストの引数ヒント（引数が空のときだけ）
  (:values ENTRIES :truncated BOOL) カーソルで選ぶ候補メニュー
  (:abort t)                        ペインを操作されたなどで取得を中止した
  nil                               これ以上の引数は無い

読み終えたら入力欄は空に戻す。"
  (let ((cached (and (buffer-live-p buf)
                     (with-current-buffer buf
                       (zellij-send--slash-arg-cached name args open)))))
    (cond
     ((not (buffer-live-p buf)) (funcall callback nil))
     (cached (funcall callback (list :values cached)))
     (t
      ;; 打つ前に入力欄が空であることを確かめる。ユーザーがターミナル側で
      ;; 書きかけたテキストの後ろに打ち足すと、その入力を壊したうえに
      ;; 画面も読み違える（実機で踏んだ）
      (zellij-send--slash-wait
       buf #'zellij-send--slash-idle-p
       (lambda (idle)
         (if (null idle)
             (progn
               (zellij-send--slash-msg
                "ペインの入力欄が空ではありません。先にペインを片付けてください")
               (funcall callback (list :abort t)))
           (zellij-send--slash-probe-write buf name args open callback))))))))

(defun zellij-send--slash-probe-write (buf name args open callback)
  "NAME の引数 ARGS の続きを聞くための文字列を入力欄に打ち、画面を読む。"
  (let ((text (zellij-send--slash-probe-text name args open)))
    (with-current-buffer buf
      (zellij-send--slash-write-chars
       zellij-send--session text
       (lambda (ok)
         (if (not ok)
             (funcall callback nil)
           ;; ヒントは本文と同じ描画で出る。取りこぼさないよう一拍置く
           (run-at-time
            zellij-send-slash-settle-delay nil
            (lambda ()
              (zellij-send--slash-wait
               buf
               (lambda (s) (let ((it (zellij-send--slash-input-text s)))
                             (and it (string-prefix-p name it))))
               (lambda (screen)
                 (zellij-send--slash-probe-read
                  buf name args open screen callback)))))))))))

(defun zellij-send--slash-probe-read (buf name args open screen callback)
  "SCREEN からヒントか候補メニューを読み、CALLBACK に渡す。
メニューが出ていたら ↓ を送りながら全件集める。"
  (let* ((empty (string-empty-p (string-trim (or args ""))))
         (hint (and screen empty (zellij-send--slash-arg-hint screen name)))
         (entries (and screen (null hint) (zellij-send--slash-arg-entries screen))))
    (cond
     (hint (zellij-send--slash-clear-input
            buf (lambda (_ok) (funcall callback (list :hint hint)))))
     (entries
      (zellij-send--slash-scroll
       buf (zellij-send--slash-arg-spec
            (zellij-send--slash-probe-text name args open))
       nil 0 0 nil nil
       (lambda (result)
         (if (null result)
             (funcall callback (list :abort t))
           (let ((values (plist-get result :entries))
                 (truncated (plist-get result :truncated)))
             (when (and values (not truncated) (buffer-live-p buf))
               (with-current-buffer buf
                 (zellij-send--slash-arg-cache-put name args open values)))
             (funcall callback (list :values values :truncated truncated)))))))
     (t (zellij-send--slash-clear-input
         buf (lambda (_ok) (funcall callback nil)))))))

;;;; 入口

(defconst zellij-send--slash-arg-max-depth 5
  "引数を何段まで聞き直すか。
`/plugin enable NAME' のように候補は入れ子になるので繰り返し聞くが、
画面を読み違えて延々と聞き続けないための歯止め。")

(defun zellij-send--slash-table (alist)
  "ALIST（(値 . 説明)）を completing-read の補完表にする。
説明は注釈で出し、並びは渡された順のまま（メニューの順に意味がある）。"
  (lambda (str pred action)
    (if (eq action 'metadata)
        `(metadata
          (annotation-function
           . ,(lambda (cand)
                (let ((desc (cdr (assoc cand alist))))
                  (when desc
                    (concat "  "
                            (truncate-string-to-width desc 70 nil nil "…"))))))
          (display-sort-function . identity))
      (complete-with-action action alist str pred))))

(defun zellij-send--slash-read (alist)
  "ALIST（(名前 . 説明)）から completing-read で 1 つ選ばせる。
`/' を初期入力にしておくので、続けて英字を打つと絞り込める。
一覧に無いコマンドも打てるように require-match しない。"
  (completing-read "スラッシュコマンド: " (zellij-send--slash-table alist)
                   nil nil "/"))

(defun zellij-send--slash-read-hint (name hint)
  "ゴーストのヒント HINT に従って NAME の引数をミニバッファで尋ねる。
パスを求めるヒントは Emacs 側でパス補完し、`a|b|c' の形は候補にする。"
  (let ((kind (zellij-send--slash-hint-kind hint))
        (values (zellij-send--slash-hint-values hint)))
    (cond
     ((eq kind 'directory)
      (expand-file-name (read-directory-name (format "%s のディレクトリ: " name))))
     ((eq kind 'file)
      (expand-file-name (read-file-name (format "%s のファイル: " name))))
     (values
      (completing-read (format "%s の引数 [%s]（空で省略）: " name hint)
                       values nil nil))
     (t (read-string (format "%s の引数 [%s]（空で省略）: " name hint))))))

(defun zellij-send--slash-read-value (name info)
  "候補メニュー INFO から 1 つ選ばせる。空で確定したら nil を返す。
返すのは (値 . 一覧にあったか)。一覧に無い値は**絞り込みの打ちかけ**として
扱い、次にそれを打った状態で候補を出し直す——メニューは実測 12 件で
頭打ちなので、数文字打って絞るのが唯一の手段になる。"
  (let* ((entries (plist-get info :values))
         (value (string-trim
                 (completing-read
                  (format "%s の引数%s（空で省略・数文字打つと絞り込み）: " name
                          (if (plist-get info :truncated) "（候補は一部）" ""))
                  (zellij-send--slash-table entries) nil nil))))
    (unless (string-empty-p value)
      (cons value (and (assoc value entries) t)))))

(defun zellij-send--slash-submit (buf name args)
  "NAME と ARGS を組み立ててペインへ送る。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((text (string-trim (concat name " " (or args "")))))
        (zellij-send--send zellij-send--session text
                           (lambda (ok)
                             (when ok (message "送信しました: %s" text))))))))

(defun zellij-send--slash-run (buf name args open depth info)
  "NAME の引数を INFO に従って尋ね、決まったら送る。
ARGS はここまでに決まった引数文字列、OPEN は末尾のトークンが書きかけか、
DEPTH は何段目か。候補は入れ子になる（`/plugin' → `enable' → プラグイン名）
ので、1 つ選ぶたびに次の段を聞き直す。"
  (when (buffer-live-p buf)
    (cond
     ((plist-get info :abort)
      (message "引数の候補を取得できませんでした。ペインの状態を確認してください"))
     ((plist-get info :hint)
      (let ((arg (zellij-send--slash-read-hint name (plist-get info :hint))))
        (zellij-send--slash-submit
         buf name (string-trim (concat args " " (or arg ""))))))
     ((plist-get info :values)
      (let ((choice (zellij-send--slash-read-value name info)))
        (if (null choice)
            (zellij-send--slash-submit buf name args)
          (let* ((value (car choice))
                 (listed (cdr choice))
                 ;; 一覧から選んだ値は、それ自体が書きかけ（`autoScroll=' の
                 ;; ような）でなければ 1 トークンぶんの確定。一覧に無い値は
                 ;; 絞り込みの打ちかけとみなして、次はそれを打った状態で聞く
                 (next-open (if listed (zellij-send--slash-arg-open-p value) t))
                 (next (zellij-send--slash-arg-append args value open)))
            (if (>= depth zellij-send--slash-arg-max-depth)
                (zellij-send--slash-submit buf name next)
              (message "%s %s の続きを確認中…" name next)
              (zellij-send--slash-probe-arg
               buf name next next-open
               (lambda (result)
                 ;; sentinel の中でミニバッファを開かない（C-g が効かなくなる）
                 (run-at-time 0 nil #'zellij-send--slash-run
                              buf name next next-open (1+ depth) result))))))))
     (t (zellij-send--slash-submit buf name args)))))

(defun zellij-send--slash-choose (buf)
  "BUF のキャッシュから選ばせ、引数を尋ねてから送る。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((name (string-trim (zellij-send--slash-read (zellij-send--slash-cached)))))
        (unless (string-empty-p name)
          (unless (string-prefix-p "/" name)
            (setq name (concat "/" name)))
          (message "%s の引数を確認中…" name)
          (zellij-send--slash-probe-arg
           buf name "" nil
           (lambda (result)
             ;; sentinel の中でミニバッファを開かない（C-g が効かなくなる）
             (run-at-time 0 nil #'zellij-send--slash-run
                          buf name "" nil 1 result))))))))

(defun zellij-send-slash-command (&optional refresh)
  "Claude Code のスラッシュコマンドを選んで送る。
コマンド一覧はペインの補完メニューから読み取り、作業ディレクトリごとに覚える
（`zellij-send-slash-prefetch' が non-nil なら黒板バッファを開いた時点で
先読みしてあるので、たいてい待ち時間は無い）。
REFRESH（`\\[universal-argument]'）を付けるとコマンド一覧と引数の候補を
取り直す。

コマンドを選ぶと引数も尋ねる。`/effort' のようにヒント（`[low|medium|…]'）
が出るものは候補から選び、`<path>' はディレクトリ補完で選ぶ。`/config' や
`/plugin' のようにペイン側でカーソルで選ぶ候補メニューが出るものは、
その候補を集めてミニバッファで選ばせる（`/plugin enable NAME' のように
入れ子になる場合は、選ぶたびに次の段を聞く）。

一覧の取得も引数の確認もペインの入力欄を実際に打って行うので、入力欄が
空でないときは何もしない。`/model' のように送信後に対話画面が出る
コマンドは、そのままキー透過モード（\\[zellij-send-keys-mode]）で操作する。"
  (interactive "P")
  (zellij-send--assert-session)
  (when refresh
    (zellij-send--slash-arg-cache-clear))
  (let ((buf (current-buffer)))
    (if (and (zellij-send--slash-cached) (not refresh))
        (zellij-send--slash-choose buf)
      (message "スラッシュコマンド一覧を取得中…（初回のみ数秒かかります）")
      (zellij-send--slash-collect
       buf
       (lambda (alist)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (if (null alist)
                 (message "コマンド一覧を取得できませんでした。ペインの状態を確認してください")
               (zellij-send--slash-cache-put alist)
               (message "スラッシュコマンド %d 件" (length alist))
               (run-at-time 0 nil #'zellij-send--slash-choose buf)))))))))

;;;; 先読み

(defun zellij-send--slash-prefetch-maybe ()
  "一覧をまだ持っていなければ、少し待ってから黙って取りに行く。
`zellij-send--subscribe-start' から呼ばれる（＝ペインに繋がった時点）。
初回の `zellij-send-slash-command' を待たせないための先読み。"
  (when (and zellij-send-slash-prefetch
             zellij-send--session
             (null (zellij-send--slash-cached))
             (not zellij-send--slash-prefetching))
    (run-at-time zellij-send-slash-prefetch-delay nil
                 #'zellij-send--slash-prefetch-run (current-buffer) 1)))

(defun zellij-send--slash-prefetch-run (buf try)
  "BUF の一覧を黙って取りに行く。TRY は何回目か。
取れなければ少し置いてやり直す——起動直後の claude は信頼確認などで
入力欄が空でないことがあり、その間は取得を諦めるため。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and zellij-send-slash-prefetch
                 zellij-send--session
                 zellij-send--pane-id
                 (null (zellij-send--slash-cached))
                 (not zellij-send--slash-prefetching)
                 (<= try zellij-send-slash-prefetch-retries))
        (setq zellij-send--slash-prefetching t)
        (zellij-send--slash-collect
         buf
         (lambda (alist)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (setq zellij-send--slash-prefetching nil)
               (if alist
                   (zellij-send--slash-cache-put alist)
                 (run-at-time zellij-send-slash-prefetch-delay nil
                              #'zellij-send--slash-prefetch-run
                              buf (1+ try)))))))))))

;;; インタラクティブコマンド

(defun zellij-send-send ()
  "バッファのテキストを zellij セッションに送信し、バッファをクリアする。"
  (interactive)
  (zellij-send--assert-session)
  (let* ((session zellij-send--session)
         (buf (current-buffer))
         (text (string-trim (buffer-string))))
    (when (string-empty-p text)
      (user-error "送信するテキストが空です"))
    ;; 失敗時に入力テキストを失わないよう、クリアは成功後に行う
    (zellij-send--send
     session text
     (lambda (ok)
       (when (and ok (buffer-live-p buf))
         (zellij-send--history-add session text)
         (with-current-buffer buf
           (erase-buffer)
           (set-buffer-modified-p nil)
           (setq zellij-send--user-cleared nil)
           ;; 送信し終えたら履歴を辿る位置はリセットする
           (setq zellij-send--history-index nil)
           (setq zellij-send--history-draft nil))
         (message "送信しました → [%s]" session))))))

(defun zellij-send-show-response (&optional arg)
  "会話の内容をバッファに表示する。
Claude Code なら黒板をクリアして transcript の会話を最初から流す
（画面には流れて消えた分が残っていないため）。それ以外のコマンドや
ARG（\\[universal-argument]）付きのときは、従来どおり zellij スクリーンを
取り直す。手動取得なのでスクロールバックまで取る（`--full'）。

表示した後は自動更新が止まる（過去の会話が subscribe の画面で
上書きされないようにするため）。生の画面に戻すには
`zellij-send-show-live'（メニュー `g'）を使う。"
  (interactive "P")
  (zellij-send--assert-session)
  (let* ((claude (and (not arg) (zellij-send--transcript-claude-p)))
         (file (and claude (zellij-send--transcript-file default-directory))))
    (cond
     (file (zellij-send--transcript-show file))
     (t
      (when claude
        (message "transcript が見つかりません。スクリーンを取得します"))
      (zellij-send--dump-screen-async
       zellij-send--session
       (lambda (content)
         (if content
             (progn
               (zellij-send--update-buffer content)
               (message "スクリーン内容を取得しました"))
           (message "スクリーン内容の取得に失敗しました")))
       t)))))

(defun zellij-send-show-live (&optional arg)
  "黒板を今のペイン画面に戻し、自動更新を再開する。

自動更新は 2 つの場合に止まっている:
transcript を表示した後（`zellij-send--user-cleared')と、
バッファを編集した後（`buffer-modified-p')。どちらも解除して
`dump-screen' で取り直すので、以後は subscribe の更新が
そのまま流れてくる。

書きかけの下書きは失われるので、編集済みのときは確認する。
ARG（\\[universal-argument]）付きならスクロールバックまで取る（`--full')。"
  (interactive "P")
  (zellij-send--assert-session)
  (when (and (buffer-modified-p)
             (not (zerop (buffer-size)))
             (not (yes-or-no-p
                   "書きかけの内容は失われます。ペインの画面に戻しますか? ")))
    (user-error "中止しました"))
  ;; 取得の完了を待たずに解除する。`--user-cleared' が立ったままだと
  ;; `--update-buffer' が書き込みを拒むため、コールバックが空振りする。
  (set-buffer-modified-p nil)
  (setq zellij-send--user-cleared nil)
  (let ((buf (current-buffer)))
    (zellij-send--dump-screen-async
     zellij-send--session
     (lambda (content)
       (if content
           (progn
             (zellij-send--update-buffer content)
             (when (buffer-live-p buf)
               (with-current-buffer buf (goto-char (point-max))))
             (message "ペインの画面に戻しました（自動更新を再開）"))
         (message "スクリーン内容の取得に失敗しました（自動更新は再開しました）")))
     arg)))

(defun zellij-send-clear-buffer ()
  "バッファの内容をクリアする。"
  (interactive)
  (erase-buffer)
  (set-buffer-modified-p nil)
  (setq zellij-send--user-cleared t)
  (message "クリアしました"))

(defun zellij-send--force-delete-session (session main-buf reason)
  "SESSION を `delete-session --force' で削除し、成功したら MAIN-BUF を kill する。
REASON はユーザーに理由を伝えるための文字列。
削除に失敗したらバッファは残す（再操作できるようにするため）。"
  (zellij-send--zellij-async
   (list "delete-session" "--force" session)
   (lambda (exit)
     (if (zerop exit)
         (progn
           (when (buffer-live-p main-buf)
             (kill-buffer main-buf))
           (message "セッション [%s] を削除しました（%s）" session reason))
       (message "セッション [%s] の削除に失敗しました (exit: %d)" session exit)))))

(defun zellij-send--parse-pane-exited (raw pane-id)
  "`action list-panes --all' の出力 RAW から PANE-ID の EXITED 列を返す。
終了していれば t、動いていれば nil、判定できなければ `:unknown'。

列は 2 個以上の空白区切りだが、TITLE や COMMAND 自体に空白が入るため
位置を決め打ちにせず、ヘッダ行から PANE_ID と EXITED の列位置を求める。"
  (let* ((lines (split-string (or raw "") "\n" t))
         (header (and lines (split-string (string-trim (car lines)) "[ \t]\\{2,\\}" t)))
         (pane-col (and header (seq-position header "PANE_ID")))
         (exited-col (and header (seq-position header "EXITED"))))
    (if (not (and pane-col exited-col))
        :unknown
      (let ((result :unknown))
        (dolist (line (cdr lines) result)
          (let ((fields (split-string (string-trim (zellij-send--strip-ansi line))
                                      "[ \t]\\{2,\\}" t)))
            ;; 列がずれている行は読まない（TITLE に 2 連空白が入った等）
            (when (and (= (length fields) (length header))
                       (equal (nth pane-col fields) pane-id))
              (setq result (string= (nth exited-col fields) "true")))))))))

(defun zellij-send--await-agent-exit (session pane-id main-buf deadline)
  "SESSION のエージェントが終了するのを待ち、確認できたらセッションを削除する。

**エージェントが終了してもセッションは消えない**（実測: /exit で claude が
落ちてもペインは EXITED=true のまま残り、セッションは list-sessions に居続ける）。
そのため「セッションが消えるのを待つ」だけでは必ずタイムアウトする。
PANE-ID が分かっていれば `list-panes --all' の EXITED 列で終了を検出し、
分かっていなければセッションの消滅を見る（ターミナル側で閉じられた場合に効く）。

DEADLINE（`float-time' の値）を過ぎたら `delete-session --force' に切り替える。
`list-sessions' の `:timeout' を「セッション 0 件」と解釈しないこと。"
  (let ((timed-out (> (float-time) deadline)))
    (cond
     (timed-out
      (zellij-send--force-delete-session
       session main-buf
       (format "%.0f 秒待っても終了しなかったので強制削除" zellij-send-quit-timeout)))
     (pane-id
      (zellij-send--zellij-output-async
       session '("action" "list-panes" "--all")
       (lambda (out)
         (let ((exited (zellij-send--parse-pane-exited out pane-id)))
           (if (eq exited t)
               (zellij-send--force-delete-session
                session main-buf "エージェントの終了を確認")
             (message "セッション [%s] を終了中..." session)
             (run-at-time zellij-send-quit-poll-interval nil
                          #'zellij-send--await-agent-exit
                          session pane-id main-buf deadline))))))
     (t
      (zellij-send--list-sessions-async
       (lambda (sessions)
         (if (and (listp sessions) (not (member session sessions)))
             (progn
               (when (buffer-live-p main-buf)
                 (kill-buffer main-buf))
               (message "セッション [%s] は終了しました" session))
           (message "セッション [%s] を終了中..." session)
           (run-at-time zellij-send-quit-poll-interval nil
                        #'zellij-send--await-agent-exit
                        session pane-id main-buf deadline))))))))

(defun zellij-send-quit ()
  "Claude Code に /exit を送り、zellij セッションとバッファを削除する。
エージェントが実際に終了するのを待ってから削除する。
`zellij-send-quit-timeout' を超えたら待つのをやめて強制削除する。
固定待ちにすると、ツール実行中で /exit が入力欄に入っただけのセッションを
根拠のない待ち時間で強制削除してしまう。"
  (interactive)
  (zellij-send--assert-session)
  (let ((session zellij-send--session)
        (pane-id zellij-send--pane-id)
        (main-buf (current-buffer)))
    (unless (yes-or-no-p
             (format "セッション [%s] を削除しますか? (zellij セッションも消えます) " session))
      (user-error "キャンセルしました"))
    (message "セッション [%s] を終了中..." session)
    (zellij-send--send
     session "/exit"
     (lambda (ok)
       (if ok
           (zellij-send--await-agent-exit
            session pane-id main-buf (+ (float-time) zellij-send-quit-timeout))
         ;; /exit が送れないなら待っても終了しないので、すぐ強制削除する
         (zellij-send--force-delete-session
          session main-buf "/exit を送信できなかったため"))))))

(defun zellij-send-open-log ()
  "Claude の出力ログ（markdown）を別ウィンドウで開く。
ログは Stop フックが `zellij-send-log-file' に追記する。"
  (interactive)
  (zellij-send--assert-session)
  (let ((file (expand-file-name zellij-send-log-file default-directory)))
    (unless (file-exists-p file)
      (user-error "ログファイルがまだありません: %s" file))
    (find-file-other-window file)))

;;; 返信バッファ

(defun zellij-send--reply-send ()
  "返信バッファの内容を送信してバッファを閉じ、元のバッファに戻る。"
  (interactive)
  (unless zellij-send--session
    (user-error "セッション情報がありません"))
  (let ((session zellij-send--session)
        (text (string-trim (buffer-string)))
        (reply-buf (current-buffer))
        (main-buf zellij-send--reply-main-buffer)
        (wconf zellij-send--reply-window-config))
    (when (string-empty-p text)
      (user-error "送信するテキストが空です"))
    ;; 失敗時は返信バッファを残してテキストを失わない
    (zellij-send--send
     session text
     (lambda (ok)
       (when ok
         (zellij-send--history-add session text)
         (when (buffer-live-p reply-buf)
           (kill-buffer reply-buf))
         (if (window-configuration-p wconf)
             (set-window-configuration wconf)
           (when (and main-buf (buffer-live-p main-buf))
             (pop-to-buffer main-buf)))
         (message "送信しました → [%s]" session))))))

(defun zellij-send-reply-number ()
  "数字を入力して zellij セッションに送信する。"
  (interactive)
  (zellij-send--assert-session)
  (let ((session zellij-send--session)
        (n (read-number "送る数字: ")))
    (zellij-send--send session (number-to-string n)
                       (lambda (ok)
                         (when ok
                           (message "送信しました: %d → [%s]" n session))))))

(defvar zellij-send-reply-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'zellij-send--reply-send)
    (define-key map (kbd "C-c C-k") #'zellij-send-interrupt)
    (define-key map (kbd "M-p")     #'zellij-send-history-prev)
    (define-key map (kbd "M-n")     #'zellij-send-history-next)
    map)
  "zellij-send 返信バッファのキーマップ。")

(defun zellij-send-reply ()
  "返信用の空バッファを開く。C-c C-c で送信してバッファを閉じる。"
  (interactive)
  (zellij-send--assert-session)
  (let* ((session zellij-send--session)
         (main-buf (current-buffer))
         (wconf (current-window-configuration))
         (reply-buf (get-buffer-create (format "*zellij-reply-%s*" session))))
    (with-current-buffer reply-buf
      (erase-buffer)
      (text-mode)
      (setq-local zellij-send--session session)
      (setq-local zellij-send--pane-id
                  (buffer-local-value 'zellij-send--pane-id main-buf))
      (setq-local zellij-send--reply-main-buffer main-buf)
      (setq-local zellij-send--reply-window-config wconf)
      (use-local-map zellij-send-reply-mode-map)
      (setq-local header-line-format
                  (format " Reply → [%s]  |  C-c C-c: 送信して閉じる" session)))
    (pop-to-buffer reply-buf)))

;;; AskUserQuestion（選択肢プロンプト）への回答

;; Claude Code の AskUserQuestion は次の形で描かれる（2026-07-29 実測、
;; Claude Code v2.1.220 / zellij 0.44.3。詳細は CLAUDE.md 参照）:
;;
;;   ←  ☐ 好きな色  ☒ 好きな果物  ✔ Submit  →   ← 質問タブ（☒ = 回答済み）
;;
;;   好きな果物はどれですか（複数選択可）？      ← 質問文
;;
;;   ❯ 1. [ ] りんご                            ← ❯ = カーソル、[ ] = 複数選択
;;     定番。シャキシャキした食感。              ← 説明（折り返すこともある）
;;     2. [✔] みかん
;;     5. [ ] Type something                    ← 自由入力
;;        Submit
;;   ────────────────────────────
;;     6. Chat about this
;;
;;   Enter to select · Tab/Arrow keys to navigate · Esc to cancel
;;
;; **数字キーが直接効く**のがこの実装の土台。単一選択なら数字 1 つで即回答して
;; 次の質問へ自動で進み、複数選択なら数字がその選択肢のトグルになる（カーソルは
;; 動かない）。したがって QR メニューのようにカーソル移動量を数える必要が無い。
;; 移動量を数えずに済むこと自体が堅牢性で、説明文の折り返しに影響されない。
;;
;; そのほか実測で確定した挙動:
;; - ←/→ が質問タブの移動。Tab は前進のみでラップしない
;; - 複数選択の質問からは → で「Review your answers」へ直行できる
;; - 自由入力（Type something）はカーソルを合わせると入力欄になる。
;;   本文は `paste' で入れる。単一選択ならそのまま Enter で確定、
;;   複数選択なら Enter は不要（→ で Review へ）
;; - 最終確認は `❯ 1. Submit answers / 2. Cancel`。ここも数字で選べる。
;;   **この画面にはヒント行が出ない**ので、ヒント行だけを検出条件にすると
;;   確認画面で止まってしまう（実機の通し確認で踏んだ）
;; - 質問が 1 つだけの単一選択にはタブ行も Review も無く、選んだ時点で確定する

(defcustom zellij-send-askq-hint-regexp "^Enter to select · .*Esc to cancel"
  "AskUserQuestion の画面を見分けるための正規表現。
Claude Code が選択肢プロンプトの最下部に必ず出すヒント行に一致する。"
  :type 'regexp
  :group 'zellij-send)

(defcustom zellij-send-askq-other-regexp "\\`Type something\\.?\\'"
  "自由入力（その他）の選択肢ラベルに一致する正規表現。"
  :type 'regexp
  :group 'zellij-send)

(defcustom zellij-send-askq-auto 'keys
  "質問を検出した時点で何を自動で開くか。

- `keys'      … キー透過モード（`zellij-send-keys-mode'）に入る。
                黒板には生画面がそのまま映っているので、説明文や事例を
                読みながら数字キー・↑↓・RET で答えられる（既定）
- `minibuffer' … ミニバッファの `completing-read' で選ばせる（旧挙動）。
                ラベルしか出ないので、説明が要る質問には向かない
- nil         … 何もしない

nil でも `zellij-send-answer-question'（C-c C-q）で手動で開ける。
互換のため t は `minibuffer' として扱う。"
  :type '(choice (const :tag "キー透過モード" keys)
                 (const :tag "ミニバッファ" minibuffer)
                 (const :tag "自動で開かない" nil))
  :group 'zellij-send)

(defun zellij-send--askq-auto-method ()
  "`zellij-send-askq-auto' を `keys' / `minibuffer' / nil に正規化する。
旧設定の t は `minibuffer'（旧挙動）に読み替える。"
  (pcase zellij-send-askq-auto
    ('keys 'keys)
    ('nil nil)
    (_ 'minibuffer)))

(defcustom zellij-send-askq-settle-delay 0.8
  "キーを送ってから画面を読み直すまでの待ち時間（秒）。"
  :type 'number
  :group 'zellij-send)

(defconst zellij-send--askq-option-regexp
  "^\\(❯\\)?[[:space:]]*\\([0-9]+\\)\\.[[:space:]]+\\(\\[\\(.\\)\\][[:space:]]+\\)?\\(.*?\\)[[:space:]]*$"
  "選択肢の行に一致する正規表現。
1=カーソル 2=番号 3=チェックボックス全体 4=チェック文字 5=ラベル。")

(defvar-local zellij-send--askq-active nil
  "直前の画面更新で質問が出ていたか。自動起動の立ち上がり検出に使う。")

(defvar-local zellij-send--askq-answering nil
  "回答フローの実行中なら non-nil。多重起動と自動起動の割り込みを防ぐ。")

(defvar-local zellij-send--askq-signature nil
  "直前に回答した画面の署名。同じ画面を繰り返し処理していないかの検査用。")

(defvar-local zellij-send--askq-repeat 0
  "同じ署名の画面を続けて処理した回数。無限ループの歯止め。")

(defvar-local zellij-send--askq-rounds 0
  "1 回の回答フローで質問を処理した回数。")

;; キー透過モードは後ろのセクションで定義するので、ここでは前方宣言だけしておく
(defvar zellij-send-keys-mode)

(defvar-local zellij-send--askq-keys-auto nil
  "質問の自動起動でキー透過モードに入ったなら non-nil。
質問が画面から消えたときに自動で抜けるのはこの場合だけ。
ユーザーが `C-c C-t' で自分で入れたモードは勝手に切らない。")

(defcustom zellij-send-askq-max-rounds 12
  "1 回の回答フローで処理する質問の上限。
これを超えたら打ち切る。署名（画面の内容）が毎回変わる形で空回りしても
必ず止まるようにするための最後の歯止め——実際、自由入力の欄に数字キーを
打ち込み続けて画面が毎回変わる不具合を踏んだことがある。"
  :type 'integer
  :group 'zellij-send)

(defconst zellij-send--askq-review-regexp "Ready to submit your answers"
  "最終確認画面を見分けるための正規表現。
確認画面にはヒント行（`zellij-send-askq-hint-regexp'）が出ない（実測）ため、
この行が確認画面を見つける唯一の目印になる。")

(defun zellij-send--askq-last-index (lines regexp)
  "LINES で REGEXP に一致する最後の行番号を返す。無ければ nil。"
  (let ((i (1- (length lines))) found)
    (while (and (>= i 0) (not found))
      (when (string-match-p regexp (nth i lines))
        (setq found i))
      (setq i (1- i)))
    found))

(defun zellij-send--askq-region-start (lines hint)
  "LINES の HINT 行より上で、質問ブロックの開始行番号を返す。
タブ行（☐ / ☒）か「Review your answers」を目印にする。
見つからなければ HINT の 25 行上で打ち切る（画面全体を舐めないため）。"
  (let ((i (1- hint))
        (floor-idx (max 0 (- hint 25)))
        (found nil))
    (while (and (>= i floor-idx) (not found))
      (when (string-match-p "[☐☒]\\|^Review your answers" (nth i lines))
        (setq found i))
      (setq i (1- i)))
    (or found floor-idx)))

(defun zellij-send--askq-separator-p (line)
  "LINE が罫線だけの行なら non-nil。"
  (string-match-p "\\`[[:space:]─━-]*\\'" line))

(defun zellij-send--askq-parse (screen)
  "SCREEN に AskUserQuestion があれば plist を返す。無ければ nil。

返す plist:
  :kind      `question' か `review'
  :question  質問文
  :multi     複数選択なら t
  :options   選択肢のリスト。各要素は
             (:num N :label \"...\" :desc \"...\" :checked BOOL
              :box BOOL :focused BOOL)"
  (when (and screen
             (or (string-match-p zellij-send-askq-hint-regexp screen)
                 (string-match-p zellij-send--askq-review-regexp screen)))
    (let* ((lines (split-string screen "\n"))
           (n (length lines))
           (hint (zellij-send--askq-last-index lines zellij-send-askq-hint-regexp))
           (rev (zellij-send--askq-last-index lines zellij-send--askq-review-regexp))
           ;; 確認画面にはヒント行が無い（実測）。どちらの目印が下にあるかで
           ;; 読む範囲を決める。ヒントだけを頼りにすると確認画面を取り逃がす
           (use-review (and rev (or (null hint) (> rev hint))))
           (region (if use-review
                       (seq-subseq lines rev (min n (+ rev 10)))
                     (seq-subseq lines
                                 (zellij-send--askq-region-start lines hint)
                                 hint)))
           (options nil)
           (question nil)
           (review nil))
      (dolist (line region)
        (cond
         ((string-match-p "Ready to submit your answers" line)
          (setq review t))
         ((string-match zellij-send--askq-option-regexp line)
          (push (list :num (string-to-number (match-string 2 line))
                      :label (match-string 5 line)
                      :desc nil
                      :checked (equal (match-string 4 line) "✔")
                      :box (and (match-string 3 line) t)
                      :focused (and (match-string 1 line) t))
                options))
         ((or (string-empty-p (string-trim line))
              (zellij-send--askq-separator-p line)
              (string-match-p "[☐☒]" line))
          nil)
         (options
          ;; 選択肢の直後の非空行は説明。折り返した 2 行目以降は捨てる
          (unless (plist-get (car options) :desc)
            (setcar options (plist-put (car options) :desc (string-trim line)))))
         (t
          ;; 選択肢より前の非空行が質問文。複数行なら最後の 1 行を採る
          (setq question (string-trim line)))))
      (when options
        (setq options (nreverse options))
        (list :kind (if review 'review 'question)
              :question (or question "質問")
              :multi (and (seq-some (lambda (o) (plist-get o :box)) options) t)
              :options options)))))

(defun zellij-send--askq-signature (q)
  "Q の同一性を判定するための文字列を返す。"
  (format "%s|%s" (plist-get q :question)
          (mapconcat (lambda (o) (format "%s%s%s"
                                         (plist-get o :num)
                                         (plist-get o :label)
                                         (if (plist-get o :checked) "*" "")))
                     (plist-get q :options) ",")))

(defun zellij-send--askq-other-p (opt)
  "OPT が自由入力（その他）の選択肢なら non-nil。"
  (string-match-p zellij-send-askq-other-regexp (plist-get opt :label)))

(defun zellij-send--askq-digits (opt)
  "OPT の番号を打つためのバイト列を返す。"
  (string-to-list (number-to-string (plist-get opt :num))))

(defun zellij-send--askq-candidate (opt)
  "OPT を completing-read の候補文字列にする。"
  (format "%d. %s%s%s"
          (plist-get opt :num)
          (if (plist-get opt :box)
              (if (plist-get opt :checked) "[✔] " "[ ] ")
            "")
          (plist-get opt :label)
          (if (plist-get opt :desc)
              (format "  — %s" (plist-get opt :desc))
            "")))

(defun zellij-send--askq-read (prompt opts &optional multi)
  "OPTS から選ばせて、選ばれた選択肢のリストを返す。
MULTI が non-nil なら複数選べる。"
  (let* ((cands (mapcar #'zellij-send--askq-candidate opts))
         (table (cl-mapcar #'cons cands opts)))
    (if multi
        (delq nil (mapcar (lambda (c) (cdr (assoc c table)))
                          (completing-read-multiple prompt cands nil t)))
      (let ((c (completing-read prompt cands nil t)))
        (list (cdr (assoc c table)))))))

;;;; 送信の下請け

(defun zellij-send--askq-send-keys (buf seq &optional callback)
  "BUF のペインへ SEQ（バイト列のリスト）を順に送る。
BUF を常にカレントにしてから送るので、pane-id を取り違えない。
最後に CALLBACK へ成功 t / 失敗 nil を渡す。"
  (if (null seq)
      (when callback (funcall callback t))
    (if (not (buffer-live-p buf))
        (when callback (funcall callback nil))
      (with-current-buffer buf
        (zellij-send--send-keys
         zellij-send--session (car seq)
         (lambda (exit)
           (if (zerop exit)
               (zellij-send--askq-send-keys buf (cdr seq) callback)
             (message "キー送信に失敗しました (exit: %d)" exit)
             (when callback (funcall callback nil)))))))))

(defun zellij-send--askq-focus (buf num callback &optional tries)
  "BUF の画面でカーソル (❯) を選択肢 NUM に合わせてから CALLBACK を呼ぶ。
移動量を一度に計算せず 1 つずつ動かして毎回確認する。説明文の折り返しで
行数がずれても壊れないようにするため（QR メニューで踏んだ失敗と同じ轍）。
CALLBACK には成功 t / 失敗 nil を渡す。"
  (let ((tries (or tries 0)))
    (if (or (not (buffer-live-p buf)) (> tries 12))
        (progn (message "カーソルを選択肢 %d に合わせられませんでした" num)
               (funcall callback nil))
      (let* ((q (with-current-buffer buf (zellij-send--askq-parse (buffer-string))))
             (opts (plist-get q :options))
             (cur (seq-position opts nil (lambda (o _) (plist-get o :focused))))
             (target (seq-position opts nil (lambda (o _) (= (plist-get o :num) num)))))
        (cond
         ((or (null cur) (null target))
          (message "画面から選択肢を読み取れませんでした")
          (funcall callback nil))
         ((= cur target) (funcall callback t))
         (t
          (zellij-send--askq-send-keys
           buf (list (if (< cur target) '(27 91 66) '(27 91 65)))
           (lambda (ok)
             (if (not ok)
                 (funcall callback nil)
               (run-at-time zellij-send-askq-settle-delay nil
                            #'zellij-send--askq-focus
                            buf num callback (1+ tries)))))))))))

;;;; 回答フロー

(defun zellij-send--askq-finish (buf)
  "回答フローを終了して BUF のフラグを戻す。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq zellij-send--askq-answering nil))))

(defun zellij-send--askq-after (buf ok)
  "キー送信の後始末。OK なら画面が落ち着いてから次の質問を探す。"
  (if (not ok)
      (zellij-send--askq-finish buf)
    (run-at-time zellij-send-askq-settle-delay nil
                 #'zellij-send--askq-continue buf)))

(defun zellij-send--askq-continue (buf)
  "BUF の画面を読み直し、まだ質問があれば続けて答える。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq zellij-send--askq-answering nil)
      (let ((q (zellij-send--askq-parse (buffer-string))))
        (cond
         ((null q)
          (setq zellij-send--askq-signature nil
                zellij-send--askq-repeat 0)
          (message "回答しました → [%s]" zellij-send--session))
         ;; 同じ画面が続くのは、キーが効いていないか読み違えている合図。
         ;; 黙って聞き続けるとミニバッファが無限に開くので必ず打ち切る
         ((and (equal zellij-send--askq-signature (zellij-send--askq-signature q))
               (>= zellij-send--askq-repeat 2))
          (setq zellij-send--askq-signature nil
                zellij-send--askq-repeat 0)
          (message "画面が変わりません。ペインを直接確認してください"))
         (t
          (if (equal zellij-send--askq-signature (zellij-send--askq-signature q))
              (setq zellij-send--askq-repeat (1+ zellij-send--askq-repeat))
            (setq zellij-send--askq-signature (zellij-send--askq-signature q)
                  zellij-send--askq-repeat 0))
          (zellij-send--askq-answer buf q)))))))

(defun zellij-send--askq-answer (buf q)
  "BUF の質問 Q に対する回答を尋ねてキーを送る。"
  (with-current-buffer buf
    (setq zellij-send--askq-answering t
          zellij-send--askq-rounds (1+ zellij-send--askq-rounds)))
  (if (> (buffer-local-value 'zellij-send--askq-rounds buf)
         zellij-send-askq-max-rounds)
      (progn
        (zellij-send--askq-finish buf)
        (message "質問を %d 回処理しても終わらないので打ち切りました。ペインを直接確認してください"
                 zellij-send-askq-max-rounds))
    (zellij-send--askq-dispatch buf q)))

(defun zellij-send--askq-dispatch (buf q)
  "Q の種類に応じた回答フローを呼ぶ。C-g は途中で抜けても後始末する。"
  (condition-case _err
      (pcase (plist-get q :kind)
        ('review (zellij-send--askq-answer-review buf q))
        (_ (if (plist-get q :multi)
               (zellij-send--askq-answer-multi buf q)
             (zellij-send--askq-answer-single buf q))))
    (quit (zellij-send--askq-finish buf)
          (message "回答を中止しました（ペインは質問のままです。Esc は C-c C-k）"))))

(defun zellij-send--askq-answer-single (buf q)
  "単一選択の質問 Q に答える。数字キー 1 つで確定し、次の質問へ自動で進む。"
  (let* ((opts (plist-get q :options))
         (opt (car (zellij-send--askq-read
                    (format "%s: " (plist-get q :question)) opts))))
    (if (zellij-send--askq-other-p opt)
        ;; 自由入力はカーソルを合わせると入力欄になる。paste して Enter で確定
        (let ((text (read-string "自由入力: ")))
          (zellij-send--askq-focus
           buf (plist-get opt :num)
           (lambda (ok)
             (if (not ok)
                 (zellij-send--askq-finish buf)
               (with-current-buffer buf
                 (zellij-send--send
                  zellij-send--session text
                  (lambda (ok2) (zellij-send--askq-after buf ok2))))))))
      (zellij-send--askq-send-keys
       buf (list (zellij-send--askq-digits opt))
       (lambda (ok) (zellij-send--askq-after buf ok))))))

(defun zellij-send--askq-answer-multi (buf q)
  "複数選択の質問 Q に答える。数字キーでトグルし、→ で確認画面へ進む。"
  (let* ((opts (plist-get q :options))
         (chosen (zellij-send--askq-read
                  (format "%s（複数可・カンマ区切り）: " (plist-get q :question))
                  opts t))
         (plain (seq-find (lambda (o) (not (plist-get o :box))) chosen)))
    (if plain
        ;; チェックボックスでない選択肢（Chat about this など）は単独で決定
        (zellij-send--askq-send-keys
         buf (list (zellij-send--askq-digits plain))
         (lambda (ok) (zellij-send--askq-after buf ok)))
      (let* ((other (seq-find #'zellij-send--askq-other-p chosen))
             (text (when other (read-string "自由入力: ")))
             (toggles (seq-filter
                       (lambda (o)
                         (and (plist-get o :box)
                              (not (eq (and (memq o chosen) t)
                                       (plist-get o :checked)))))
                       opts))
             (keys (mapcar #'zellij-send--askq-digits toggles)))
        (zellij-send--askq-send-keys
         buf keys
         (lambda (ok)
           (cond
            ((not ok) (zellij-send--askq-finish buf))
            (other
             (run-at-time zellij-send-askq-settle-delay nil
                          #'zellij-send--askq-fill-other buf other text))
            (t (zellij-send--askq-submit-multi buf nil)))))))))

(defun zellij-send--askq-fill-other (buf other text)
  "複数選択の自由入力 OTHER に TEXT を書き込んでから確認画面へ進む。
数字キーでトグルしただけではラベルは Type something のままなので、
カーソルを合わせてから `paste' する（Enter は不要）。"
  (zellij-send--askq-focus
   buf (plist-get other :num)
   (lambda (ok)
     (if (not ok)
         (zellij-send--askq-finish buf)
       (with-current-buffer buf
         (zellij-send--zellij-async
          (append (list "--session" zellij-send--session "action" "paste")
                  (zellij-send--pane-args)
                  (list "--" text))
          (lambda (exit)
            (if (zerop exit)
                (zellij-send--askq-submit-multi buf t)
              (message "自由入力の送信に失敗しました (exit: %d)" exit)
              (zellij-send--askq-finish buf)))))))))

(defun zellij-send--askq-submit-multi (buf from-text)
  "複数選択の質問を確定して次のタブ（確認画面）へ進む。

FROM-TEXT が non-nil なら、カーソルは自由入力の欄にある。
**その状態では ←/→ はタブ移動ではなく入力欄内のカーソル移動になる**
（実機で踏んだ。→ を送っても質問画面から出られず、次の周回で数字キーが
入力欄に打ち込まれて `自由入力テスト4444…' になった）。
入力欄の直下は必ず `Submit' 行なので、↓ と Enter で確定する。
それ以外は → でタブを進める（どちらも実測で確認済み）。"
  (run-at-time
   zellij-send-askq-settle-delay nil
   (lambda ()
     (zellij-send--askq-send-keys
      buf (if from-text '((27 91 66) (13)) '((27 91 67)))
      (lambda (ok) (zellij-send--askq-after buf ok))))))

(defun zellij-send--askq-answer-review (buf q)
  "確認画面 Q で送信するかを尋ねる。"
  (let* ((opts (plist-get q :options))
         (submit (seq-find (lambda (o) (string-match-p "Submit" (plist-get o :label))) opts))
         (cancel (seq-find (lambda (o) (string-match-p "Cancel" (plist-get o :label))) opts))
         (opt (if (y-or-n-p "この内容で回答を送信しますか? ") submit cancel)))
    (if (null opt)
        (progn (message "確認画面の選択肢を読み取れませんでした")
               (zellij-send--askq-finish buf))
      (zellij-send--askq-send-keys
       buf (list (zellij-send--askq-digits opt))
       (lambda (ok) (zellij-send--askq-after buf ok))))))

;;;; 入口と自動起動

(defun zellij-send-answer-question ()
  "画面に出ている AskUserQuestion に Emacs 側で答える。
選択肢をミニバッファで選ぶと、対応する数字キーをペインへ送る。
質問が複数ある場合は最後の確認画面まで続けて尋ねる。"
  (interactive)
  (zellij-send--assert-session)
  (let ((q (zellij-send--askq-parse (buffer-string))))
    (unless q
      (user-error "画面に選択肢プロンプトが見つかりません"))
    (setq zellij-send--askq-signature (zellij-send--askq-signature q)
          zellij-send--askq-repeat 0
          zellij-send--askq-rounds 0)
    (zellij-send--askq-answer (current-buffer) q)))

(defun zellij-send--askq-auto-open (buf)
  "BUF に質問が出たので回答 UI を開く。
`zellij-send--update-buffer' から `run-at-time' 経由で呼ばれる。
プロセスフィルタの中でミニバッファを開かないための遠回りなので、
ここを直接呼び出しに変えないこと。"
  (when (and (buffer-live-p buf)
             (not (minibufferp))
             (not (active-minibuffer-window)))
    (with-current-buffer buf
      (unless zellij-send--askq-answering
        (when (zellij-send--askq-parse (buffer-string))
          ;; 表示はするがウィンドウは選ばない（別バッファでの作業を邪魔しない）
          (display-buffer buf)
          (pcase (zellij-send--askq-auto-method)
            ('keys (zellij-send--askq-keys-enter))
            ('minibuffer (call-interactively #'zellij-send-answer-question))))))))

(defun zellij-send--askq-keys-enter ()
  "質問が出たのでキー透過モードに入る。カレントバッファで呼ぶ。
既に入っているなら何もしない（自動で入ったという印も付け替えない）。"
  (unless zellij-send-keys-mode
    (setq zellij-send--askq-keys-auto t)
    (zellij-send-keys-mode 1)
    (message "質問です。%s に移って数字 / ↑↓ / RET で答えてください（C-c C-t で解除）"
             (buffer-name))))

(defun zellij-send--askq-keys-exit ()
  "質問が消えたので、自動で入ったキー透過モードだけ抜ける。"
  (when (and zellij-send--askq-keys-auto zellij-send-keys-mode)
    (zellij-send-keys-mode -1))
  (setq zellij-send--askq-keys-auto nil))

(defun zellij-send--askq-maybe-auto ()
  "画面更新のたびに呼ばれ、質問が出た瞬間だけ回答 UI を開く。
質問が消えたときは、自動で入ったキー透過モードを元に戻す。"
  (let ((now (and (zellij-send--askq-parse (buffer-string)) t)))
    (cond
     ((and now
           (not zellij-send--askq-active)
           (zellij-send--askq-auto-method)
           (not zellij-send--askq-answering))
      (run-at-time 0 nil #'zellij-send--askq-auto-open (current-buffer)))
     ((and (not now) zellij-send--askq-keys-auto)
      (zellij-send--askq-keys-exit)))
    (setq zellij-send--askq-active now)))

;;; キー透過モード

;; `*ai-SESSION*' バッファには subscribe 経由でペインの生画面が 26〜40 ms 遅れで
;; 映っている。つまり「見る」側は既に完成しているので、足りないのは「打つ」側だけ。
;; このモードを有効にすると、矢印・Enter・Space・Tab・Esc・印字文字を
;; バッファ編集ではなく `zellij-send--send-keys' でペインへ流す。
;; AskUserQuestion の選択肢・権限ダイアログ・`/model' の選択など、
;; **画面の中身を解釈せずに**あらゆる TUI を Emacs から操作できる。
;;
;; 有効中はバッファを read-only にする。誤ってバッファを編集すると
;; `buffer-modified-p' が真になり、自動更新が抑止されて画面が固まったように
;; 見えるため（`zellij-send--update-buffer' の抑止条件）。

(defvar-local zellij-send--keys-saved-read-only nil
  "キー透過モードに入る前の `buffer-read-only' の値。")

(defun zellij-send--keys-send (bytes)
  "BYTES をペインへ送る。キー透過モード用の薄いラッパ。"
  (zellij-send--assert-session)
  (zellij-send--send-keys
   zellij-send--session bytes
   (lambda (exit)
     (unless (zerop exit)
       (message "キー送信に失敗しました (exit: %d)" exit)))))

(defun zellij-send--keys-define (map key bytes)
  "MAP の KEY に BYTES を送るコマンドを割り当てる。"
  (define-key map (kbd key)
              (lambda ()
                (interactive)
                (zellij-send--keys-send bytes))))

(defun zellij-send-keys-self-insert ()
  "押した印字文字をそのままペインへ送る。
`self-insert-command' の差し替え先。マルチバイト文字も送れるよう
UTF-8 のバイト列に分解してから送る。"
  (interactive)
  (let ((bytes (string-to-list (encode-coding-string (string last-command-event)
                                                     'utf-8))))
    (zellij-send--keys-send bytes)))

(defvar zellij-send-keys-mode-map
  (let ((map (make-sparse-keymap)))
    ;; 矢印は CSI シーケンス（↑ = ESC [ A）。1 回の write にまとめて送る
    (zellij-send--keys-define map "<up>"    '(27 91 65))
    (zellij-send--keys-define map "<down>"  '(27 91 66))
    (zellij-send--keys-define map "<right>" '(27 91 67))
    (zellij-send--keys-define map "<left>"  '(27 91 68))
    (zellij-send--keys-define map "C-p"     '(27 91 65))
    (zellij-send--keys-define map "C-n"     '(27 91 66))
    (zellij-send--keys-define map "C-f"     '(27 91 67))
    (zellij-send--keys-define map "C-b"     '(27 91 68))
    (zellij-send--keys-define map "RET"     '(13))
    (zellij-send--keys-define map "TAB"     '(9))
    (zellij-send--keys-define map "<backtab>" '(27 91 90))
    (zellij-send--keys-define map "<escape>" '(27))
    (zellij-send--keys-define map "DEL"     '(127))
    (define-key map [remap self-insert-command] #'zellij-send-keys-self-insert)
    (define-key map (kbd "C-c C-t") #'zellij-send-keys-mode)
    (define-key map (kbd "C-g")     #'zellij-send-keys-quit)
    map)
  "キー透過モードのキーマップ。ここにあるキーはペインへ送られる。")

(define-minor-mode zellij-send-keys-mode
  "有効な間、キー入力を zellij ペインへそのまま送る。
選択肢の上下移動 (↑↓)、決定 (RET)、複数選択のトグル (SPC)、
中止 (ESC)、数字キーなどが Emacs バッファではなくペインに届く。
`C-c C-t' か `C-g' で抜ける。"
  :lighter " →zellij"
  :keymap zellij-send-keys-mode-map
  (if zellij-send-keys-mode
      (progn
        ;; `define-minor-mode' はこの本体より先に変数を t にするため、
        ;; セッションが無いときは自分で false に戻してから抜ける
        (unless zellij-send--session
          (setq zellij-send-keys-mode nil)
          (user-error "zellij-send バッファ外では使えません"))
        (setq zellij-send--keys-saved-read-only buffer-read-only)
        (setq buffer-read-only t)
        (message "キー透過モード ON（↑↓ 選択 / RET 決定 / SPC トグル / C-c C-t で解除）"))
    (setq buffer-read-only zellij-send--keys-saved-read-only)
    ;; 手で抜けたら「自動で入った」印も落とす。次に自分で入れ直したモードを
    ;; 質問が消えた拍子に勝手に切らないため
    (setq zellij-send--askq-keys-auto nil)
    (message "キー透過モード OFF")))

(defun zellij-send-keys-quit ()
  "キー透過モードを抜ける。"
  (interactive)
  (zellij-send-keys-mode -1))

;;; Transient メニュー

(defun zellij-send-open-dashboard ()
  "セッション一覧ダッシュボードを開く。
`zellij-send-dashboard' が読み込まれていない場合は require を試みる。
本体はダッシュボードに依存しない（依存は dashboard → 本体の一方向）。"
  (interactive)
  (unless (fboundp 'zellij-send-dashboard)
    (unless (require 'zellij-send-dashboard nil t)
      (user-error "zellij-send-dashboard が読み込まれていません")))
  (call-interactively 'zellij-send-dashboard))

(transient-define-prefix zellij-send-menu ()
  "ZellijSend メニュー"
  [["表示"
    ("d" "ダッシュボード（セッション一覧）" zellij-send-open-dashboard)
    ("a" "会話の履歴を表示 (transcript)" zellij-send-show-response)
    ("g" "いまの画面に戻す（自動更新を再開）" zellij-send-show-live)
    ("l" "出力ログを開く (markdown)" zellij-send-open-log)
    ("x" "表示内容をクリア"         zellij-send-clear-buffer)]
   ["送信"
    ("e" "答える（返信バッファを開く）" zellij-send-reply)
    ("n" "答える（数字を送る）"         zellij-send-reply-number)
    ("h" "送信履歴から選ぶ"             zellij-send-history-select)
    ("u" "質問に答える (AskUserQuestion)" zellij-send-answer-question)
    ("k" "キー透過モード（↑↓ RET SPC）" zellij-send-keys-mode)]
   ["命令"
    ("i" "中断 (Esc)"              zellij-send-interrupt)
    ("/" "スラッシュコマンド (/…)" zellij-send-slash-command)
    ("s" "作業を記録"              zellij-send-save-progress)
    ("+" "エージェントを増やす（同じ場所にもう1体）" zellij-send-add-agent)
    ("q" "終了（セッション削除）"  zellij-send-quit)]])

;;; メジャーモード

(defvar zellij-send-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'zellij-send-send)
    (define-key map (kbd "C-c C-a") #'zellij-send-menu)
    (define-key map (kbd "C-c C-k") #'zellij-send-interrupt)
    (define-key map (kbd "C-c C-t") #'zellij-send-keys-mode)
    (define-key map (kbd "C-c C-q") #'zellij-send-answer-question)
    (define-key map (kbd "C-c C-s") #'zellij-send-slash-command)
    (define-key map (kbd "M-p")     #'zellij-send-history-prev)
    (define-key map (kbd "M-n")     #'zellij-send-history-next)
    map)
  "zellij-send-mode のキーマップ。")

(defun zellij-send--mode-setup ()
  "zellij-send-mode の共通セットアップ処理。"
  (setq-local header-line-format
              '(:eval (if zellij-send-keys-mode
                          (format " Session: %s  |  ⌨ キー透過中: ↑↓ 選択 / RET 決定 / SPC トグル / C-c C-t 解除"
                                  (or zellij-send--session "?"))
                        (format " Session: %s  |  C-c C-c: 送信  C-c C-a: メニュー  C-c C-t: キー透過"
                                (or zellij-send--session "?")))))
  ;; subscribe はセッション名が入ってから張る（`--get-or-create-buffer' が呼ぶ）。
  ;; ここで確実に止めておかないと、常駐プロセスがバッファより長生きする
  ;; ——セッションが消えても subscribe 自身は終了しないため、これが唯一の
  ;; 確実な後始末になる。
  (add-hook 'kill-buffer-hook #'zellij-send--subscribe-stop nil t))

(if (require 'markdown-mode nil t)
    (define-derived-mode zellij-send-mode markdown-mode "ZellijSend"
      "zellij セッションにテキストを送るためのモード。
\\{zellij-send-mode-map}"
      (zellij-send--mode-setup))
  (define-derived-mode zellij-send-mode text-mode "ZellijSend"
    "zellij セッションにテキストを送るためのモード。
\\{zellij-send-mode-map}"
    (zellij-send--mode-setup)))

;;; Stop フックハンドラ

;;;###autoload
(defun zellij-send--on-claude-stop ()
  "Claude Code 停止時に全 zellij-send バッファを dump-screen で更新する。
~/.claude/hooks/stop-zellij-send.sh から emacsclient 経由で呼ばれる。
ユーザーが意図してクリアしたバッファは更新しない。"
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (eq major-mode 'zellij-send-mode)
                   zellij-send--session
                   (not zellij-send--user-cleared)
                   (not (buffer-modified-p)))
          (zellij-send--dump-screen-async
           zellij-send--session
           (lambda (content)
             (when (and content
                        (not zellij-send--user-cleared)
                        (not (buffer-modified-p)))
               (zellij-send--update-buffer content)))))))))

;;; エントリポイント

(defun zellij-send--prompt-session-dir ()
  "作業ディレクトリをユーザーに選択させ、末尾スラッシュなしの絶対パスを返す。"
  (directory-file-name
   (expand-file-name
    (read-directory-name "作業ディレクトリ: " default-directory))))

(defun zellij-send--session-base (session)
  "SESSION 名から末尾 2 桁の連番を取り除いた基底名を返す。
連番が無ければ SESSION をそのまま返す。
桁数を 2 に固定しているのは `zellij-send--numbered-session-name' が
必ず 2 桁で作るため。数字を貪欲に剥がすと `project200'（= project2 の
1 体目）の基底名が `project' になってしまう。"
  (if (string-match "\\`\\(.+\\)[0-9][0-9]\\'" session)
      (match-string 1 session)
    session))

(defun zellij-send--numbered-session-name (base taken)
  "BASE に 2 桁の連番を付け、TAKEN に無い最小の名前を返す。
同じプロジェクトで複数のエージェントを立てるための命名
\(`myproj00' / `myproj01' …)。1 体目から連番を付ける。"
  (let ((n 0))
    (while (member (format "%s%02d" base n) taken)
      (setq n (1+ n)))
    (format "%s%02d" base n)))

(defun zellij-send--taken-session-names (&optional sessions)
  "使用済みセッション名のリストを返す。
SESSIONS（zellij から取った一覧）に加え、黒板バッファが握っている
セッション名も含める。作成直後でまだ `list-sessions' に出ていない
セッションと衝突しないようにするため。"
  (delete-dups
   (append (copy-sequence sessions)
           (delq nil
                 (mapcar (lambda (buf)
                           (buffer-local-value 'zellij-send--session buf))
                         (buffer-list))))))

(defun zellij-send--setup-session-buffer (session dir)
  "SESSION 用バッファを作成し default-directory を DIR に設定して表示する。
作成したバッファを返す。"
  (let ((buf (zellij-send--get-or-create-buffer session)))
    (with-current-buffer buf
      (setq-local default-directory (file-name-as-directory dir)))
    (switch-to-buffer buf)
    (goto-char (point-max))
    buf))

(defun zellij-send--run-in-session-async (session dir command callback)
  "SESSION に新しいペインを作って COMMAND（文字列）を起動する。
DIR はペインの作業ディレクトリ。成功したら pane-id（例: \"terminal_2\"）を、
失敗したら nil を CALLBACK に渡す。attach クライアントは不要（zellij 0.44+）。"
  (let ((out-buf (generate-new-buffer " *zellij-run*"))
        (err-buf (generate-new-buffer " *zellij-run-err*"))
        (process-environment (zellij-send--process-environment)))
    (make-process
     :name "zellij-run"
     :buffer out-buf
     :stderr err-buf
     :noquery t
     :command (append (list zellij-send-executable "--session" session
                            "run" "--cwd" dir "--name" command "--")
                      (split-string command))
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((out (with-current-buffer out-buf (buffer-string))))
           (ignore-errors (kill-buffer out-buf))
           (ignore-errors (kill-buffer err-buf))
           (funcall callback
                    (and (zerop (process-exit-status proc))
                         (string-match "terminal_[0-9]+" out)
                         (match-string 0 out)))))))))

;;; セッションの拡幅（一瞬だけ attach する）

;; 背景セッションは 50 桁 × 48 行に固定され、COLUMNS / LINES では変えられない
;; （実測。CLAUDE.md「背景セッションの大きさ」参照）。唯一効くのが、目的の
;; 大きさの pty を持つクライアントで一瞬 attach して detach する方法。
;; サイズは detach 後も残り、あとから `zellij run' で足したペインも継承する。
;;
;; **このパッケージは attach クライアント（eat）起因のフリーズが解消できず
;; eat を全廃した経緯がある。** 復活させるにあたって以下を必ず守ること:
;; 1. 全面非同期。同期呼び出しを一切挟まない
;; 2. 出力を捨てるフィルタを必ず置く。Emacs が pty を読まないと zellij サーバが
;;    クライアントへの書き込みでブロックし、セッション全体が入力不可になる
;;    （旧デッドロックの原因はこれ）
;; 3. detach に失敗しても必ずプロセスを殺す。キーバインドを変更している環境では
;;    Ctrl+o d が効かない

(defun zellij-send--resize-session (session &optional callback)
  "SESSION を `zellij-send-session-size' の大きさに広げる。
その大きさの pty を持つクライアントで一瞬 attach し、detach して返る。
終わったら CALLBACK を呼ぶ（拡幅した場合 t、無効なら nil）。

`zellij-send-session-size' が nil なら何もせず CALLBACK を呼ぶ。"
  (let ((size zellij-send-session-size))
    (if (not size)
        (when callback (funcall callback nil))
      (let* ((cols (car size))
             (rows (cdr size))
             (process-environment
              (append (list (format "COLUMNS=%d" cols)
                            (format "LINES=%d" rows))
                      (zellij-send--process-environment)))
             (finished nil)
             detach-timer watchdog proc)
        (setq proc
              (make-process
               :name (format "zellij-resize-%s" session)
               :buffer nil
               :noquery t
               :connection-type 'pty
               :command (list zellij-send-executable "attach" session)
               ;; 出力は捨てるが、フィルタは必ず置く（上記 2）
               :filter #'ignore
               :sentinel
               (lambda (p _event)
                 (when (and (not finished)
                            (memq (process-status p) '(exit signal)))
                   (setq finished t)
                   (when (timerp detach-timer) (cancel-timer detach-timer))
                   (when (timerp watchdog) (cancel-timer watchdog))
                   (when callback (funcall callback t))))))
        ;; pty の大きさを与える。zellij は接続時にこれを読み、
        ;; 後から変わっても SIGWINCH で拾う
        (ignore-errors (set-process-window-size proc rows cols))
        ;; 繋がってサイズが伝わるのを待ってから detach（Ctrl+o d）
        (setq detach-timer
              (run-at-time zellij-send-resize-detach-delay nil
                           (lambda ()
                             (when (process-live-p proc)
                               (ignore-errors
                                 (process-send-string proc "\C-od"))))))
        ;; detach が効かなくても必ず落とす（上記 3）
        (setq watchdog
              (run-at-time zellij-send-resize-timeout nil
                           (lambda ()
                             (when (process-live-p proc)
                               (delete-process proc)))))))))

(defun zellij-send-resize-session ()
  "このバッファのセッションを `zellij-send-session-size' の大きさに広げる。
背景セッション（`[New]' で作ったもの）は 50 桁しかないため、既に作って
しまったセッションを後から広げるのに使う。
ターミナルから作ったセッションはそのターミナルの幅なので通常は不要。"
  (interactive)
  (zellij-send--assert-session)
  (unless zellij-send-session-size
    (user-error "zellij-send-session-size が nil です"))
  (let ((session zellij-send--session))
    (message "セッション [%s] を %d 桁 × %d 行に広げています..."
             session (car zellij-send-session-size) (cdr zellij-send-session-size))
    (zellij-send--resize-session
     session
     (lambda (resized)
       (message "セッション [%s] の拡幅%s" session
                (if resized "が完了しました" "は行いませんでした"))))))

(defun zellij-send--spawn-session (session dir)
  "SESSION という名前の detached zellij セッションを DIR に作り、ペインを起動する。
attach クライアント（eat）は使わない: `zellij attach --create-background' で
セッションを作り、`zellij run' で `zellij-send-default-command' を起動して
返る pane-id を保持し、以後 --pane-id 指定で送受信する。
黒板バッファは同期で用意して表示し、cwd・pane-id は後から埋まる。"
  (let ((buf (zellij-send--setup-session-buffer session dir)))
    (zellij-send--zellij-async
     (list "attach" "--create-background" session)
     (lambda (exit)
       (if (not (zerop exit))
           (message "zellij セッション作成に失敗しました (exit: %d)" exit)
         ;; ペインを作る前に広げる。背景セッションは 50 桁しかなく、
         ;; あとから作るペインは拡幅後のサイズを継承する
         (zellij-send--resize-session
          session
          (lambda (_resized)
            ;; セッション初期化を待ってから claude ペインを起動
            (run-with-timer
             0.5 nil
             (lambda ()
               (zellij-send--run-in-session-async
                session dir zellij-send-default-command
                (lambda (pane-id)
                  (if (not pane-id)
                      (message "%s の起動に失敗しました"
                               zellij-send-default-command)
                    (when (buffer-live-p buf)
                      (with-current-buffer buf
                        (setq-local zellij-send--pane-id pane-id)
                        (zellij-send--subscribe-ensure)))
                    ;; `attach --create-background' が生むデフォルト shell ペイン
                    ;; （terminal_0）を閉じ、claude ペインだけを残す。失敗しても
                    ;; 致命的ではないので結果は無視する。
                    (zellij-send--zellij-async
                     (list "--session" session "action" "close-pane"
                           "--pane-id" "terminal_0")
                     #'ignore)
                    (message "セッション [%s] を作成しました (%s)"
                             session pane-id)))))))))))
    buf))

(defun zellij-send--create-new-session (known-sessions)
  "作業ディレクトリを尋ね、新しい zellij セッションを作る。
セッション名はディレクトリ名 + 2 桁の連番（`myproj00'）。
KNOWN-SESSIONS は連番を決めるための既存セッション名リスト。"
  (let* ((dir (zellij-send--prompt-session-dir))
         (session (zellij-send--numbered-session-name
                   (file-name-nondirectory dir)
                   (zellij-send--taken-session-names known-sessions))))
    (zellij-send--spawn-session session dir)))

(defun zellij-send-add-agent ()
  "同じディレクトリにもう 1 体エージェントを立ち上げる。
いまの黒板バッファの作業ディレクトリと基底名を引き継ぎ、空いている
連番（`myproj00' → `myproj01'）で新しい zellij セッションを作る。
セッションは 1 体につき 1 つなので、送信・subscribe・`zellij-send-quit'
はいずれも既存のまま各バッファ単位で効く。"
  (interactive)
  (zellij-send--assert-session)
  (let ((base (zellij-send--session-base zellij-send--session))
        (dir (directory-file-name (expand-file-name default-directory))))
    (message "セッション一覧を取得中...")
    (zellij-send--list-sessions-async
     (lambda (sessions)
       (if (eq sessions :timeout)
           (message "zellij の応答がタイムアウトしました（5秒）。zellij が正常に動作しているか確認してください。")
         (let ((session (zellij-send--numbered-session-name
                         base (zellij-send--taken-session-names sessions))))
           ;; sentinel の中でバッファを切り替えない（`zellij-send' と同じ約束）。
           (run-at-time 0 nil #'zellij-send--spawn-session session dir)))))))

(defun zellij-send--connect-existing-session (session)
  "既存 SESSION 用の黒板バッファを開く。
cwd と pane-id は zellij から取得するので、ディレクトリは尋ねない
\(`zellij-send-attach-session-async' 参照)。pane-id が取れなかった
場合のみ focused pane 送信になり、ターミナルでの attach が要る。"
  (let ((known (get-buffer (zellij-send--buffer-name session))))
    ;; バッファ生成は同期。cwd と pane-id は後から非同期で埋まる。
    (switch-to-buffer (zellij-send--get-or-create-buffer session))
    (goto-char (point-max))
    (unless known
      (zellij-send-attach-session-async
       session
       (lambda (buf)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (message "セッション [%s] に接続しました%s" session
                      (if zellij-send--pane-id
                          (format " (%s)" zellij-send--pane-id)
                        "（pane-id 不明: ターミナルで attach が必要です）")))))))))

(defun zellij-send--select-session (sessions)
  "SESSIONS からセッションを選ばせ、対応するバッファを開く。
ミニバッファ入力を含むため、プロセス sentinel の中から直接呼ばないこと
\(`zellij-send' 参照)。"
  (let* ((choices (append sessions (list "[New]")))
         (choice (completing-read "Session: " choices nil t)))
    (if (string= choice "[New]")
        (zellij-send--create-new-session sessions)
      (zellij-send--connect-existing-session choice))))

;;;###autoload
(defun zellij-send ()
  "zellij セッションを選択して入力バッファを開く。"
  (interactive)
  (message "セッション一覧を取得中...")
  (zellij-send--list-sessions-async
   (lambda (sessions)
     (if (eq sessions :timeout)
         (message "zellij の応答がタイムアウトしました（5秒）。zellij が正常に動作しているか確認してください。")
       ;; コールバックはプロセス sentinel の中で走る。sentinel 内では
       ;; quit が抑止されるため、そのままミニバッファ入力を行うと C-g が
       ;; 効かない・入力が壊れる。タイマーで sentinel を抜けてから聞く。
       (run-at-time 0 nil #'zellij-send--select-session sessions)))))

(provide 'zellij-send)
;;; zellij-send.el ends here
