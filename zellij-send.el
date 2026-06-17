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

(require 'cl-lib)
(require 'transient)

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

(defcustom zellij-send-poll-interval 2.0
  "ポーリング間隔（秒）。0 でポーリング無効。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-ready-regexp "^❯\\s-*$"
  "AIツールが入力待ちに戻ったことを示すプロンプトの正規表現。
Claude Code のデフォルトは ❯。Gemini CLI 等では変更する。"
  :type 'regexp
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

(defvar-local zellij-send--timer nil
  "ポーリングタイマー。")

(defvar-local zellij-send--prompt-active nil
  "選択肢プロンプトが表示中なら non-nil。")

(defvar-local zellij-send--user-cleared nil
  "ユーザーが意図してクリアした場合 non-nil。ポーリング・Stop フックの上書きを防ぐ。")

(defvar-local zellij-send--reply-main-buffer nil
  "返信バッファを開いた元の zellij-send バッファ。")

(defvar-local zellij-send--reply-window-config nil
  "返信バッファを開く前のウィンドウ構成。")

(defvar-local zellij-send--notifying nil
  "AI応答完了の通知中なら non-nil。modeline 表示に使う。")

(defvar-local zellij-send--was-busy nil
  "直前のポーリングで AI が処理中だった場合 non-nil。
busy → ready への遷移を検出するために使う。")

(defmacro zellij-send--assert-session ()
  "カレントバッファが zellij-send セッションに紐付いていなければエラーを発する。"
  '(unless zellij-send--session
     (user-error "zellij-send バッファ外では使えません")))

;;; セッション一覧の取得

(defun zellij-send--parse-sessions (raw)
  "RAW テキスト（list-sessions 出力）からセッション名リストを返す。"
  (delq nil
        (mapcar (lambda (line)
                  (let ((clean (replace-regexp-in-string
                                "\033\\[[0-9;]*m" "" line)))
                    (when (string-match "^\\([^ \t]+\\)" clean)
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
        (setq zellij-send--session session)))
    buf))

;;; 送信

(defun zellij-send--process-environment ()
  "TERM を `zellij-send-term' に差し替えた `process-environment' を返す。
Emacs 既定の TERM=dumb が zellij サーバ・ペインに継承されるのを防ぐ。"
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
失敗時はメッセージも表示する。"
  (let ((pane-args (zellij-send--pane-args)))
    (zellij-send--zellij-async
     (append (list "--session" session "action" "write-chars")
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

;;; スクリーンダンプ

(defun zellij-send--strip-ansi (str)
  "STR から ANSI エスケープシーケンスを除去して返す。"
  (let ((result str))
    (setq result (replace-regexp-in-string "\033\\[[0-9;?]*[A-Za-z]" "" result))
    (setq result (replace-regexp-in-string "\033." "" result))
    result))

(defun zellij-send--process-dump (raw)
  "dump-screen の生テキスト RAW を整形して返す。"
  (replace-regexp-in-string "^─+" ""
   (zellij-send--strip-ansi
    (replace-regexp-in-string "\r" "" raw))))

(defun zellij-send--dump-screen-async (session callback)
  "SESSION のスクリーン内容を非同期で取得する（STDOUT 直読み・zellij 0.44+）。
カレントバッファに `zellij-send--pane-id' があればそのペインをダンプする。
取得できたら整形済み文字列を、失敗時は nil を引数にして CALLBACK を呼ぶ。
CALLBACK は要求元バッファをカレントにした状態で呼ばれる。"
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

;;; プロンプト検出・ハイライト

(defun zellij-send--detect-prompt ()
  "バッファに Claude Code の選択肢プロンプトがあれば non-nil を返す。"
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "❯[[:space:]]*[1-9]\\." nil t)))

(defun zellij-send--highlight-prompt ()
  "選択肢行をハイライトする。"
  (remove-overlays (point-min) (point-max) 'zellij-send-prompt t)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^.*❯[[:space:]]*[1-9]\\..*$" nil t)
      (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
        (overlay-put ov 'zellij-send-prompt t)
        (overlay-put ov 'face 'highlight)))))

;;; バッファ更新（共通処理）

(defun zellij-send--update-buffer (content)
  "バッファを CONTENT で更新し、プロンプト検出・ハイライトを実行する。"
  (with-silent-modifications
    (erase-buffer)
    (insert content)
    (goto-char (point-min)))
  (set-buffer-modified-p nil)
  (if (zellij-send--detect-prompt)
      (progn
        (setq zellij-send--prompt-active t)
        (zellij-send--highlight-prompt)
        (message "選択: 1 / 2 / 3 キーで選択できます"))
    (setq zellij-send--prompt-active nil)
    (remove-overlays (point-min) (point-max) 'zellij-send-prompt t)))

;;; 通知

(defun zellij-send--is-ready (content)
  "CONTENT の末尾5行に `zellij-send-ready-regexp' がマッチすれば non-nil を返す。"
  (let* ((lines (split-string content "\n"))
         (tail (last lines 5))
         (tail-str (mapconcat #'identity tail "\n")))
    (string-match-p zellij-send-ready-regexp tail-str)))

(defun zellij-send--mode-line-indicator ()
  "作業中・完了の zellij-send バッファがあれば modeline 用文字列を返す。"
  (let* ((live-bufs (cl-remove-if-not #'buffer-live-p (buffer-list)))
         (working-bufs (cl-remove-if-not
                        (lambda (buf)
                          (buffer-local-value 'zellij-send--was-busy buf))
                        live-bufs))
         (notifying-bufs (cl-remove-if-not
                          (lambda (buf)
                            (buffer-local-value 'zellij-send--notifying buf))
                          live-bufs))
         (session-names (lambda (bufs)
                          (mapconcat
                           (lambda (buf)
                             (buffer-local-value 'zellij-send--session buf))
                           bufs ", ")))
         (parts (list (when notifying-bufs
                        (format "☝ done! (%s)" (funcall session-names notifying-bufs)))
                      (when working-bufs
                        (format "✍ working (%s)" (funcall session-names working-bufs))))))
    (let ((str (mapconcat #'identity (delq nil parts) "  ")))
      (if (string-empty-p str) "" (concat " " str)))))

(defun zellij-send--clear-notification-on-switch (&rest _)
  "カレントバッファが通知中の zellij-send バッファなら通知をクリアする。"
  (when (and (eq major-mode 'zellij-send-mode)
             zellij-send--notifying)
    (setq zellij-send--notifying nil)
    (force-mode-line-update t)))

(defun zellij-send--update-busy-state (ready)
  "READY に基づいて busy/notifying 状態を遷移させる。
READY が non-nil かつ直前が busy なら通知を発火し、was-busy をクリアする。
READY が nil（= AI が処理中）なら was-busy フラグを立てる。"
  (cond
   ((and ready zellij-send--was-busy)
    (setq zellij-send--was-busy nil)
    (setq zellij-send--notifying t)
    (force-mode-line-update t))
   ((not ready)
    (setq zellij-send--was-busy t))))

;;; ポーリング

(defun zellij-send--poll ()
  "タイマーコールバック。dump-screen を非同期で要求し、結果が来たらバッファを更新する。"
  (when (and (buffer-live-p (current-buffer))
             zellij-send--session
             (not (buffer-modified-p))
             (not zellij-send--user-cleared))
    (zellij-send--dump-screen-async
     zellij-send--session
     (lambda (content)
       (when (and content
                  (not (buffer-modified-p))
                  (not zellij-send--user-cleared)
                  (not (string= content (buffer-string))))
         (zellij-send--update-buffer content)
         (zellij-send--update-busy-state (zellij-send--is-ready content)))))))

(defun zellij-send--start-polling ()
  "ポーリングタイマーを開始する。"
  (when (and (> zellij-send-poll-interval 0)
             (null zellij-send--timer))
    (let ((buf (current-buffer)))
      (setq zellij-send--timer
            (run-at-time zellij-send-poll-interval zellij-send-poll-interval
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (zellij-send--poll)))))))))

(defun zellij-send--stop-polling ()
  "ポーリングタイマーを停止する。"
  (when zellij-send--timer
    (cancel-timer zellij-send--timer)
    (setq zellij-send--timer nil)))

;;; 選択肢の即送信

(defun zellij-send--select-or-insert (n)
  "プロンプト中なら N 番を送信、そうでなければ数字を挿入する。"
  (if zellij-send--prompt-active
      (progn
        (zellij-send--assert-session)
        (zellij-send--send zellij-send--session (number-to-string n)
                           (lambda (ok)
                             (when ok
                               (message "選択 %d を送信しました" n))))
        (setq zellij-send--prompt-active nil)
        (remove-overlays (point-min) (point-max) 'zellij-send-prompt t))
    (insert (number-to-string n))))

(defun zellij-send-select-1 () (interactive) (zellij-send--select-or-insert 1))
(defun zellij-send-select-2 () (interactive) (zellij-send--select-or-insert 2))
(defun zellij-send-select-3 () (interactive) (zellij-send--select-or-insert 3))

;;; Claude Code コマンド

(defun zellij-send-compact ()
  "セッションに /compact を送信してコンテキストを圧縮する。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--send zellij-send--session "/compact"
                     (lambda (ok)
                       (when ok (message "圧縮しました")))))

(defun zellij-send-cc-clear ()
  "セッションに /clear を送信してコンテキストをリセットする。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--send zellij-send--session "/clear"
                     (lambda (ok)
                       (when ok (message "クリアしました（コンテキスト）")))))

(defun zellij-send-save-progress ()
  "現在の作業内容を CLAUDE.md に記録するよう依頼する。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--send zellij-send--session
                     "ここまでの作業内容と決定事項を CLAUDE.md に追記して"
                     (lambda (ok)
                       (when ok (message "記録を依頼しました")))))

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
         (with-current-buffer buf
           (erase-buffer)
           (set-buffer-modified-p nil)
           (setq zellij-send--user-cleared nil))
         (message "送信しました → [%s]" session))))))

(defun zellij-send-show-response ()
  "zellij スクリーンの内容をバッファに取得・表示する。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--dump-screen-async
   zellij-send--session
   (lambda (content)
     (if content
         (progn
           (zellij-send--update-buffer content)
           (message "スクリーン内容を取得しました"))
       (message "スクリーン内容の取得に失敗しました")))))

(defun zellij-send-clear-buffer ()
  "バッファの内容をクリアする。"
  (interactive)
  (erase-buffer)
  (set-buffer-modified-p nil)
  (setq zellij-send--user-cleared t)
  (message "クリアしました"))

(defun zellij-send-quit ()
  "Claude Code に /exit を送り、zellij セッションとバッファを削除する。"
  (interactive)
  (zellij-send--assert-session)
  (let ((session zellij-send--session)
        (main-buf (current-buffer)))
    (unless (yes-or-no-p
             (format "セッション [%s] を削除しますか? (zellij セッションも消えます) " session))
      (user-error "キャンセルしました"))
    ;; Claude Code に /exit を送信（失敗しても続行）
    (zellij-send--send session "/exit")
    (message "セッション [%s] を終了中..." session)
    ;; 2秒後にセッションを強制削除してバッファを閉じる
    (run-with-timer
     2.0 nil
     (lambda ()
       (zellij-send--zellij-async
        (list "delete-session" "--force" session)
        (lambda (_exit)
          (when (buffer-live-p main-buf)
            (kill-buffer main-buf))
          (message "セッション [%s] を削除しました" session)))))))

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

;;; Transient メニュー

(transient-define-prefix zellij-send-menu ()
  "ZellijSend メニュー"
  [["表示"
    ("a" "Claude Code の回答を表示" zellij-send-show-response)
    ("l" "出力ログを開く (markdown)" zellij-send-open-log)
    ("x" "表示内容をクリア"         zellij-send-clear-buffer)
    ("q" "終了"                     zellij-send-quit)]
   ["送信"
    ("e" "答える（返信バッファを開く）" zellij-send-reply)
    ("n" "答える（数字を送る）"         zellij-send-reply-number)]
   ["命令"
    ("c" "圧縮 (/compact)"         zellij-send-compact)
    ("C" "リセット (/clear)"       zellij-send-cc-clear)
    ("s" "作業を記録"              zellij-send-save-progress)]])

;;; メジャーモード

(defvar zellij-send-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'zellij-send-send)
    (define-key map (kbd "C-c C-a") #'zellij-send-menu)
    (define-key map (kbd "1") #'zellij-send-select-1)
    (define-key map (kbd "2") #'zellij-send-select-2)
    (define-key map (kbd "3") #'zellij-send-select-3)
    map)
  "zellij-send-mode のキーマップ。")

(defun zellij-send--mode-setup ()
  "zellij-send-mode の共通セットアップ処理。"
  (setq-local header-line-format
              '(:eval (format " Session: %s  |  C-c C-c: 送信  C-c C-a: メニュー"
                              (or zellij-send--session "?"))))
  (zellij-send--start-polling)
  (add-hook 'kill-buffer-hook #'zellij-send--stop-polling nil t)
  (add-hook 'window-buffer-change-functions
            #'zellij-send--clear-notification-on-switch))

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
               (zellij-send--update-buffer content)
               (when (zellij-send--is-ready content)
                 (setq zellij-send--notifying t)
                 (force-mode-line-update t))))))))))

;;; エントリポイント

(defun zellij-send--prompt-session-dir ()
  "作業ディレクトリをユーザーに選択させ、末尾スラッシュなしの絶対パスを返す。"
  (directory-file-name
   (expand-file-name
    (read-directory-name "作業ディレクトリ: " default-directory))))

(defun zellij-send--assert-session-unique (session known-sessions)
  "SESSION が KNOWN-SESSIONS に含まれる場合 user-error を発する。"
  (when (member session known-sessions)
    (user-error "セッション「%s」はすでに存在します" session)))

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

(defun zellij-send--create-new-session (known-sessions)
  "新規 detached zellij セッションを作成し claude ペインを起動する。
attach クライアント（eat）は使わない: `zellij attach --create-background' で
セッションを作り、`zellij run' で `zellij-send-default-command' を起動して
返る pane-id を保持し、以後 --pane-id 指定で送受信する。
KNOWN-SESSIONS は重複チェック用のセッション名リスト。"
  (let* ((dir (zellij-send--prompt-session-dir))
         (session (file-name-nondirectory dir)))
    (zellij-send--assert-session-unique session known-sessions)
    (let ((buf (zellij-send--setup-session-buffer session dir)))
      (zellij-send--zellij-async
       (list "attach" "--create-background" session)
       (lambda (exit)
         (if (not (zerop exit))
             (message "zellij セッション作成に失敗しました (exit: %d)" exit)
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
                       (setq-local zellij-send--pane-id pane-id)))
                   (message "セッション [%s] を作成しました (%s)"
                            session pane-id))))))))))))

(defun zellij-send--connect-existing-session (session)
  "既存 SESSION 用の黒板バッファを開く。
pane-id は不明なため focused pane へ送信する。完全に detached な
セッションには届かないので、その場合はターミナルで attach しておくこと。"
  (if (get-buffer (zellij-send--buffer-name session))
      (progn
        (switch-to-buffer (zellij-send--get-or-create-buffer session))
        (goto-char (point-max)))
    (let ((dir (zellij-send--prompt-session-dir)))
      (zellij-send--setup-session-buffer session dir))))

;;;###autoload
(defun zellij-send ()
  "zellij セッションを選択して入力バッファを開く。"
  (interactive)
  (message "セッション一覧を取得中...")
  (zellij-send--list-sessions-async
   (lambda (sessions)
     (if (eq sessions :timeout)
         (message "zellij の応答がタイムアウトしました（5秒）。zellij が正常に動作しているか確認してください。")
       (let* ((choices (append sessions (list "[New]")))
              (choice (completing-read "Session: " choices nil t)))
         (if (string= choice "[New]")
             (zellij-send--create-new-session sessions)
           (zellij-send--connect-existing-session choice)))))))

(add-to-list 'global-mode-string
             '(:eval (zellij-send--mode-line-indicator)) t)

(provide 'zellij-send)
;;; zellij-send.el ends here
