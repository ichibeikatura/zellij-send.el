;;; zellij-send.el --- Send text to zellij sessions from Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Emacs から zellij セッションに日本語文字列を送る拡張。
;; M-x zellij-send でセッション選択、C-c C-c で送信、C-c C-a でメニュー。

;;; Code:

(require 'transient)

(defgroup zellij-send nil
  "Send text to zellij sessions."
  :group 'tools)

(defcustom zellij-send-executable "zellij"
  "Path to the zellij executable."
  :type 'string
  :group 'zellij-send)

(defvar-local zellij-send--session nil
  "このバッファに対応する zellij セッション名。")

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
    (message "送信しました → [%s]" session)))

;;; スクリーンダンプ

(defun zellij-send--strip-ansi (str)
  "STR から ANSI エスケープシーケンスを除去して返す。"
  (let ((result str))
    ;; CSI シーケンス: ESC [ ... 終端文字
    (setq result (replace-regexp-in-string "\033\\[[0-9;?]*[A-Za-z]" "" result))
    ;; その他の ESC + 1文字シーケンス
    (setq result (replace-regexp-in-string "\033." "" result))
    result))

(defun zellij-send--dump-screen (session)
  "SESSION のスクリーン内容を文字列として返す。"
  (let ((tmpfile (make-temp-file "zellij-dump-")))
    (unwind-protect
        (progn
          (call-process zellij-send-executable nil nil nil
                        "--session" session
                        "action" "dump-screen" tmpfile)
          (let ((raw (with-temp-buffer
                       (insert-file-contents tmpfile)
                       (buffer-string))))
            (zellij-send--strip-ansi
             (replace-regexp-in-string "\r" "" raw))))
      (when (file-exists-p tmpfile)
        (delete-file tmpfile)))))

;;; インタラクティブコマンド

(defun zellij-send-show-response ()
  "zellij スクリーンの内容をバッファに取得・表示する。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (let* ((session zellij-send--session)
         (content (zellij-send--dump-screen session)))
    (erase-buffer)
    (insert content)
    (goto-char (point-min))
    (message "スクリーン内容を取得しました")))

(defun zellij-send-clear-buffer ()
  "バッファの内容をクリアする。"
  (interactive)
  (erase-buffer)
  (message "クリアしました"))

(defun zellij-send-quit ()
  "セッションに /exit を送り、バッファを閉じる。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (let ((session zellij-send--session))
    (zellij-send--send session "/exit")
    (kill-buffer (current-buffer))))

;;; Transient メニュー

(transient-define-prefix zellij-send-menu ()
  "ZellijSend メニュー"
  [["表示"
    ("a" "Claude Code の回答を表示" zellij-send-show-response)
    ("c" "表示内容をクリア"         zellij-send-clear-buffer)
    ("q" "終了"                     zellij-send-quit)]])

;;; メジャーモード

(defvar zellij-send-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'zellij-send-send)
    (define-key map (kbd "C-c C-a") #'zellij-send-menu)
    map)
  "zellij-send-mode のキーマップ。")

(define-derived-mode zellij-send-mode text-mode "ZellijSend"
  "zellij セッションにテキストを送るためのモード。
\\{zellij-send-mode-map}"
  (setq-local header-line-format
              '(:eval (format " Session: %s  |  C-c C-c: 送信  C-c C-a: メニュー"
                              (or zellij-send--session "?")))))

;;; Stop フックハンドラ

(defun zellij-send--on-claude-stop ()
  "Claude Code 停止時に全 zellij-send バッファを dump-screen で更新する。
~/.claude/hooks/stop-zellij-send.sh から emacsclient 経由で呼ばれる。"
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (eq major-mode 'zellij-send-mode)
                   zellij-send--session)
          (let ((content (zellij-send--dump-screen zellij-send--session)))
            (erase-buffer)
            (insert content)
            (goto-char (point-min))))))))

;;; エントリポイント

;;;###autoload
(defun zellij-send ()
  "zellij セッションを選択して入力バッファを開く。"
  (interactive)
  (let ((sessions (zellij-send--list-sessions)))
    (unless sessions
      (user-error "zellij セッションが見つかりません"))
    (let* ((session (completing-read "Session: " sessions nil t))
           (buf (zellij-send--get-or-create-buffer session)))
      (switch-to-buffer buf)
      (goto-char (point-max)))))

(provide 'zellij-send)
;;; zellij-send.el ends here
