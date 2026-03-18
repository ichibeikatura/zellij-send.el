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

;;; セッション一覧の取得

(defun zellij-send--list-sessions ()
  "zellij list-sessions の出力をパースしてセッション名リストを返す。"
  (let ((raw (shell-command-to-string
              (concat zellij-send-executable " list-sessions 2>/dev/null"))))
    (delq nil
          (mapcar (lambda (line)
                    (let ((clean (replace-regexp-in-string
                                  "\033\\[[0-9;]*m" "" line)))
                      (when (string-match "^\\([^ \t]+\\)" clean)
                        (match-string 1 clean))))
                  (split-string raw "\n" t)))))

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

(defun zellij-send--send (session text)
  "SESSION に TEXT を送り、Enter キー（0x0D）を送信する。"
  (let ((exit1 (call-process zellij-send-executable nil nil nil
                             "--session" session
                             "action" "write-chars" text))
        (exit2 (call-process zellij-send-executable nil nil nil
                             "--session" session
                             "action" "write" "13")))
    (unless (zerop exit1)
      (user-error "zellij テキスト送信失敗 (exit: %d)" exit1))
    (unless (zerop exit2)
      (user-error "zellij Enter 送信失敗 (exit: %d)" exit2))))

(defun zellij-send-send ()
  "バッファのテキストを zellij セッションに送信し、バッファをクリアする。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (let* ((session zellij-send--session)
         (text (string-trim (buffer-string))))
    (when (string-empty-p text)
      (user-error "送信するテキストが空です"))
    (zellij-send--send session text)
    (erase-buffer)
    (set-buffer-modified-p nil)
    (setq zellij-send--user-cleared nil)
    (message "送信しました → [%s]" session)))

;;; スクリーンダンプ

(defun zellij-send--strip-ansi (str)
  "STR から ANSI エスケープシーケンスを除去して返す。"
  (let ((result str))
    (setq result (replace-regexp-in-string "\033\\[[0-9;?]*[A-Za-z]" "" result))
    (setq result (replace-regexp-in-string "\033." "" result))
    result))

(defun zellij-send--dump-screen (session)
  "SESSION のスクリーン内容を文字列として返す。失敗時は nil を返す。"
  (let ((tmpfile (make-temp-file "zellij-dump-")))
    (unwind-protect
        (let ((exit-code (call-process zellij-send-executable nil nil nil
                                       "--session" session
                                       "action" "dump-screen" tmpfile)))
          (if (zerop exit-code)
              (let ((raw (with-temp-buffer
                           (insert-file-contents tmpfile)
                           (buffer-string))))
                (replace-regexp-in-string "^─+" ""
                 (zellij-send--strip-ansi
                  (replace-regexp-in-string "\r" "" raw))))
            nil))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

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
  "通知中の zellij-send バッファがあれば modeline 用文字列を返す。"
  (let ((notifying-bufs
         (cl-remove-if-not
          (lambda (buf)
            (and (buffer-live-p buf)
                 (buffer-local-value 'zellij-send--notifying buf)))
          (buffer-list))))
    (if notifying-bufs
        (propertize (format " [AI Done:%s]"
                            (mapconcat
                             (lambda (buf)
                               (buffer-local-value 'zellij-send--session buf))
                             notifying-bufs ","))
                    'face 'warning)
      "")))

(defun zellij-send--clear-notification-on-switch (&rest _)
  "カレントバッファが通知中の zellij-send バッファなら通知をクリアする。"
  (when (and (eq major-mode 'zellij-send-mode)
             zellij-send--notifying)
    (setq zellij-send--notifying nil)
    (force-mode-line-update t)))

;;; ポーリング

(defun zellij-send--poll ()
  "タイマーコールバック。バッファが未編集かつユーザーがクリアしていなければ dump-screen で更新する。"
  (when (and (buffer-live-p (current-buffer))
             zellij-send--session
             (not (buffer-modified-p))
             (not zellij-send--user-cleared))
    (let ((content (zellij-send--dump-screen zellij-send--session)))
      (when (and content (not (string= content (buffer-string))))
        (zellij-send--update-buffer content)
        (let ((ready (zellij-send--is-ready content)))
          (cond
           ((and ready zellij-send--was-busy)
            (setq zellij-send--was-busy nil)
            (setq zellij-send--notifying t)
            (force-mode-line-update t))
           ((not ready)
            (setq zellij-send--was-busy t))))))))

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
        (unless zellij-send--session
          (user-error "zellij-send バッファ外では使えません"))
        (zellij-send--send zellij-send--session (number-to-string n))
        (setq zellij-send--prompt-active nil)
        (remove-overlays (point-min) (point-max) 'zellij-send-prompt t)
        (message "選択 %d を送信しました" n))
    (insert (number-to-string n))))

(defun zellij-send-select-1 () (interactive) (zellij-send--select-or-insert 1))
(defun zellij-send-select-2 () (interactive) (zellij-send--select-or-insert 2))
(defun zellij-send-select-3 () (interactive) (zellij-send--select-or-insert 3))

;;; Claude Code コマンド

(defun zellij-send-compact ()
  "セッションに /compact を送信してコンテキストを圧縮する。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (zellij-send--send zellij-send--session "/compact")
  (message "圧縮しました"))

(defun zellij-send-cc-clear ()
  "セッションに /clear を送信してコンテキストをリセットする。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (zellij-send--send zellij-send--session "/clear")
  (message "クリアしました（コンテキスト）"))

(defun zellij-send-save-progress ()
  "現在の作業内容を CLAUDE.md に記録するよう依頼する。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (zellij-send--send zellij-send--session
                     "ここまでの作業内容と決定事項を CLAUDE.md に追記して")
  (message "記録を依頼しました"))

;;; インタラクティブコマンド

(defun zellij-send-show-response ()
  "zellij スクリーンの内容をバッファに取得・表示する。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (let ((content (zellij-send--dump-screen zellij-send--session)))
    (if content
        (progn
          (zellij-send--update-buffer content)
          (message "スクリーン内容を取得しました"))
      (message "スクリーン内容の取得に失敗しました"))))

(defun zellij-send-clear-buffer ()
  "バッファの内容をクリアする。"
  (interactive)
  (erase-buffer)
  (set-buffer-modified-p nil)
  (setq zellij-send--user-cleared t)
  (message "クリアしました"))

(defun zellij-send-quit ()
  "セッションに /exit を送り、バッファを閉じる。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (let ((session zellij-send--session))
    (zellij-send--send session "/exit")
    (kill-buffer (current-buffer))))

;;; 返信バッファ

(defun zellij-send--reply-send ()
  "返信バッファの内容を送信してバッファを閉じ、元のバッファに戻る。"
  (interactive)
  (unless zellij-send--session
    (user-error "セッション情報がありません"))
  (let ((session zellij-send--session)
        (text (string-trim (buffer-string)))
        (main-buf zellij-send--reply-main-buffer)
        (wconf zellij-send--reply-window-config))
    (when (string-empty-p text)
      (user-error "送信するテキストが空です"))
    (zellij-send--send session text)
    (kill-buffer (current-buffer))
    (if (window-configuration-p wconf)
        (set-window-configuration wconf)
      (when (and main-buf (buffer-live-p main-buf))
        (pop-to-buffer main-buf)))
    (message "送信しました → [%s]" session)))

(defun zellij-send-reply-number ()
  "数字を入力して zellij セッションに送信する。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (let ((n (read-number "送る数字: ")))
    (zellij-send--send zellij-send--session (number-to-string n))
    (message "送信しました: %d → [%s]" n zellij-send--session)))

(defvar zellij-send-reply-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'zellij-send--reply-send)
    map)
  "zellij-send 返信バッファのキーマップ。")

(defun zellij-send-reply ()
  "返信用の空バッファを開く。C-c C-c で送信してバッファを閉じる。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
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
          (let ((content (zellij-send--dump-screen zellij-send--session)))
            (when content
              (zellij-send--update-buffer content)
              (when (zellij-send--is-ready content)
                (setq zellij-send--notifying t)
                (force-mode-line-update t)))))))))

;;; エントリポイント

(defun zellij-send--guess-directory (session)
  "SESSION 名に対応するディレクトリを推定して返す。見つからなければ nil。"
  (let ((home-dir (expand-file-name session "~/")))
    (cond
     ((string= (file-name-nondirectory
                (directory-file-name default-directory))
               session)
      default-directory)
     ((file-directory-p home-dir)
      (file-name-as-directory home-dir))
     (t nil))))

(defun zellij-send--create-new-session ()
  "新規 zellij セッションを作成して `zellij-send-default-command' を起動する。"
  (let* ((dir (directory-file-name
               (expand-file-name
                (read-directory-name "作業ディレクトリ: " default-directory))))
         (session (file-name-nondirectory dir))
         (sessions (zellij-send--list-sessions)))
    (when (member session sessions)
      (user-error "セッション「%s」はすでに存在します" session))
    (start-process "zellij-new-session" nil
                   zellij-send-executable
                   "--session" session
                   "options" "--default-cwd" dir)
    (sleep-for 0.5)
    (zellij-send--send session zellij-send-default-command)
    (let ((buf (zellij-send--get-or-create-buffer session)))
      (with-current-buffer buf
        (setq-local default-directory (file-name-as-directory dir)))
      (switch-to-buffer buf)
      (goto-char (point-max)))))

;;;###autoload
(defun zellij-send ()
  "zellij セッションを選択して入力バッファを開く。"
  (interactive)
  (let* ((sessions (zellij-send--list-sessions))
         (choices (append sessions (list "[New]")))
         (choice (completing-read "Session: " choices nil t)))
    (if (string= choice "[New]")
        (zellij-send--create-new-session)
      (let ((buf (zellij-send--get-or-create-buffer choice)))
        (let ((dir (zellij-send--guess-directory choice)))
          (when dir
            (with-current-buffer buf
              (setq-local default-directory dir))))
        (switch-to-buffer buf)
        (goto-char (point-max))))))

(add-to-list 'global-mode-string
             '(:eval (zellij-send--mode-line-indicator)) t)

(provide 'zellij-send)
;;; zellij-send.el ends here
