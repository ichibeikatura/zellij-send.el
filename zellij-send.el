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

(defcustom zellij-send-poll-interval 2.0
  "ポーリング間隔（秒）。0 でポーリング無効。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-ready-regexp "^❯\\s-*$"
  "AIツールが入力待ちに戻ったことを示すプロンプトの正規表現。
Claude Code のデフォルトは ❯。Gemini CLI 等では変更する。"
  :type 'regexp
  :group 'zellij-send)

(defvar-local zellij-send--session nil
  "このバッファに対応する zellij セッション名。")

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

(defun zellij-send--zellij-async (args &optional callback)
  "zellij を ARGS で非同期実行する。
終了したら CALLBACK に exit code を渡して呼ぶ（CALLBACK は省略可）。
同期 `call-process' は使わない: Emacs がブロックすると eat の attach
クライアントの pty を読めなくなり、zellij サーバごと（ターミナル側の
クライアントも含めて）デッドロックするため。"
  (make-process
   :name "zellij-async"
   :buffer nil
   :noquery t
   :command (cons zellij-send-executable args)
   :sentinel
   (lambda (proc _event)
     (when (memq (process-status proc) '(exit signal))
       (when callback
         (funcall callback (process-exit-status proc)))))))

(defun zellij-send--send (session text &optional callback)
  "SESSION に TEXT を送り、続けて Enter キー（0x0D）を非同期送信する。
完了したら CALLBACK に成功なら t、失敗なら nil を渡して呼ぶ（省略可）。
失敗時はメッセージも表示する。"
  (zellij-send--zellij-async
   (list "--session" session "action" "write-chars" text)
   (lambda (exit1)
     (if (not (zerop exit1))
         (progn
           (message "zellij テキスト送信失敗 (exit: %d)" exit1)
           (when callback (funcall callback nil)))
       (zellij-send--zellij-async
        (list "--session" session "action" "write" "13")
        (lambda (exit2)
          (if (not (zerop exit2))
              (progn
                (message "zellij Enter 送信失敗 (exit: %d)" exit2)
                (when callback (funcall callback nil)))
            (when callback (funcall callback t)))))))))

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
  "SESSION のスクリーン内容を非同期で取得する。
取得できたら整形済み文字列を、失敗時は nil を引数にして CALLBACK を呼ぶ。
CALLBACK は要求元バッファをカレントにした状態で呼ばれる。"
  (let ((tmpfile (make-temp-file "zellij-dump-"))
        (req-buffer (current-buffer)))
    (make-process
     :name "zellij-dump"
     :buffer nil
     :noquery t
     :command (list zellij-send-executable
                    "--session" session
                    "action" "dump-screen" "--path" tmpfile)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (unwind-protect
             (let ((content
                    (when (and (zerop (process-exit-status proc))
                               (file-exists-p tmpfile))
                      (zellij-send--process-dump
                       (with-temp-buffer
                         (insert-file-contents tmpfile)
                         (buffer-string))))))
               (when (buffer-live-p req-buffer)
                 (with-current-buffer req-buffer
                   (funcall callback content))))
           (when (file-exists-p tmpfile)
             (delete-file tmpfile))))))))

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
  "Claude Code に /exit を送り、シェルを終了し、zellij セッションとバッファを削除する。"
  (interactive)
  (zellij-send--assert-session)
  (let ((session zellij-send--session)
        (main-buf (current-buffer)))
    (unless (yes-or-no-p
             (format "セッション [%s] を削除しますか? (eat バッファ・zellij セッションも消えます) " session))
      (user-error "キャンセルしました"))
    ;; 1. Claude Code に /exit を送信（失敗しても続行）
    (zellij-send--send session "/exit")
    (message "セッション [%s] を終了中..." session)
    ;; 2. 2秒後にシェルへ exit を送信（Claude Code 終了後のシェルを抜ける）
    (run-with-timer
     2.0 nil
     (lambda ()
       (zellij-send--send session "exit")
       ;; 3. さらに 1.5秒後にクリーンアップ
       (run-with-timer
        1.5 nil
        (lambda ()
          ;; eat バッファのプロセスを終了してバッファを閉じる
          (when-let ((eat-buf (get-buffer (zellij-send--eat-buffer-name session))))
            (when (buffer-live-p eat-buf)
              (ignore-errors
                (when-let ((proc (get-buffer-process eat-buf)))
                  (set-process-query-on-exit-flag proc nil)
                  (delete-process proc)))
              (with-current-buffer eat-buf
                (set-buffer-modified-p nil))
              (kill-buffer eat-buf)))
          ;; zellij セッションが残っていれば削除
          (zellij-send--zellij-async
           (list "delete-session" session)
           (lambda (_exit)
             ;; 黒板バッファを閉じる
             (when (buffer-live-p main-buf)
               (kill-buffer main-buf))
             (message "セッション [%s] を削除しました" session)))))))))

(defun zellij-send-open-eat ()
  "このセッションの eat バッファをビューモードで開く。なければ zellij attach -c で起動する。"
  (interactive)
  (zellij-send--assert-session)
  (let* ((session zellij-send--session)
         (existing (get-buffer (zellij-send--eat-buffer-name session)))
         (buf (or existing (zellij-send--launch-eat-session session))))
    (unless existing
      (run-with-timer 0.5 nil (lambda ()
                                (when (buffer-live-p buf)
                                  (with-current-buffer buf
                                    (eat-emacs-mode))))))
    (pop-to-buffer buf)))

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
    ("t" "端末で表示 (eat)"         zellij-send-open-eat)
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
  ;; eat の attach 確立（0.5〜1.0 秒）より後にポーリングを開始して競合を避ける
  (let ((buf (current-buffer)))
    (run-with-timer 1.5 nil
                    (lambda ()
                      (when (buffer-live-p buf)
                        (with-current-buffer buf
                          (zellij-send--start-polling))))))
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

(defun zellij-send--eat-buffer-name (session)
  "SESSION に対応する eat バッファ名を返す。"
  (format "*eat-%s*" session))

(defun zellij-send--launch-eat-session (session &optional dir)
  "eat バッファで SESSION に zellij attach -c を実行し、バッファを返す。
DIR が指定された場合はそのディレクトリで起動する（新規セッション用）。"
  (unless (require 'eat nil t)
    (user-error "eat がインストールされていません（M-x package-install RET eat）"))
  (let* ((default-directory (if dir (file-name-as-directory dir) default-directory))
         (buf (eat-make (zellij-send--eat-buffer-name session)
                        zellij-send-executable
                        nil
                        "attach" "-c" session)))
    (when-let ((proc (get-buffer-process buf)))
      (let ((prev (process-sentinel proc)))
        (set-process-sentinel
         proc
         (lambda (p status)
           (when prev (funcall prev p status))
           (let ((b (process-buffer p)))
             (when (buffer-live-p b)
               (kill-buffer b)))))))
    buf))

(defun zellij-send--setup-session-buffer (session dir)
  "SESSION 用バッファを作成し default-directory を DIR に設定して表示する。"
  (let ((buf (zellij-send--get-or-create-buffer session)))
    (with-current-buffer buf
      (setq-local default-directory (file-name-as-directory dir)))
    (switch-to-buffer buf)
    (goto-char (point-max))))

(defun zellij-send--create-new-session (known-sessions)
  "新規 zellij セッションを作成して `zellij-send-default-command' を起動する。
KNOWN-SESSIONS は重複チェック用のセッション名リスト。"
  (let* ((dir (zellij-send--prompt-session-dir))
         (session (file-name-nondirectory dir)))
    (zellij-send--assert-session-unique session known-sessions)
    (let ((eat-buf (zellij-send--launch-eat-session session dir)))
      (run-with-timer 1.0 nil
                      (lambda ()
                        (when (buffer-live-p eat-buf)
                          (when-let ((proc (get-buffer-process eat-buf)))
                            (process-send-string proc
                                                 (concat zellij-send-default-command "\n")))))))
    (zellij-send--setup-session-buffer session dir)))

(defun zellij-send--connect-existing-session (session)
  "既存 SESSION に接続し、黒板バッファと eat バッファを開く。"
  (let* ((eat-existing (get-buffer (zellij-send--eat-buffer-name session)))
         (eat-buf (or eat-existing (zellij-send--launch-eat-session session))))
    (unless eat-existing
      (run-with-timer 0.5 nil
                      (lambda ()
                        (when (buffer-live-p eat-buf)
                          (with-current-buffer eat-buf
                            (eat-emacs-mode))))))
    (if (get-buffer (zellij-send--buffer-name session))
        (progn
          (switch-to-buffer (zellij-send--get-or-create-buffer session))
          (goto-char (point-max)))
      (let ((dir (zellij-send--prompt-session-dir)))
        (zellij-send--setup-session-buffer session dir)))))

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
