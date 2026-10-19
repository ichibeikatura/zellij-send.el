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
;;
;; ファイルの構成（依存は上から下の一方向）:
;;   zellij-send.el          入口。セッションの選択と作成
;;   zellij-send-ui.el       黒板バッファ・メニュー・公開 API
;;   zellij-send-claude.el   Claude Code 専用の機能
;;   zellij-send-core.el     zellij の呼び出し・状態・送受信
;;   zellij-send-parse.el    画面と transcript の解析
;; `(require 'zellij-send)' だけで全部読み込まれる。

;;; Code:

(require 'zellij-send-ui)

;;; エントリポイント

;; ここに置くのは「どのディレクトリに、どのコマンドで、どの名前で」を尋ねる
;; 部分だけ。セッションを作る・繋ぐ処理は下の層の公開 API
;; （`zellij-send-spawn-session' / `zellij-send-attach-session'）にある。

(defun zellij-send--prompt-session-dir ()
  "作業ディレクトリをユーザーに選択させ、末尾スラッシュなしの絶対パスを返す。"
  (directory-file-name
   (expand-file-name
    (read-directory-name "作業ディレクトリ: " default-directory))))

(defun zellij-send--prompt-command (&optional default)
  "起動するコマンドを尋ねる。DEFAULT（既定は `zellij-send-default-command'）が初期値。
候補は `zellij-send-agents' の名前だが、一覧に無いコマンドも入力できる。
ミニバッファ入力を含むため、プロセス sentinel の中から呼ばないこと。"
  (let* ((default (or default zellij-send-default-command))
         (input (string-trim
                 (completing-read (format "Command (default %s): " default)
                                  (mapcar #'car zellij-send-agents)
                                  nil nil nil nil default))))
    (if (string-empty-p input) default input)))

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
           (mapcar #'zellij-send-session-name (zellij-send-sessions)))))

(defun zellij-send--spawn-and-show (session dir command)
  "SESSION を DIR に COMMAND で作り（`zellij-send-spawn-session'）、黒板を表示する。"
  (switch-to-buffer (zellij-send-spawn-session session dir command))
  (goto-char (point-max)))

(defun zellij-send--create-new-session (known-sessions)
  "作業ディレクトリと起動するコマンドを尋ね、新しい zellij セッションを作る。
セッション名はディレクトリ名 + 2 桁の連番（`myproj00'）。
KNOWN-SESSIONS は連番を決めるための既存セッション名リスト。"
  (let* ((dir (zellij-send--prompt-session-dir))
         (command (zellij-send--prompt-command))
         (session (zellij-send--numbered-session-name
                   (file-name-nondirectory dir)
                   (zellij-send--taken-session-names known-sessions))))
    (zellij-send--spawn-and-show session dir command)))

(defun zellij-send-add-agent (&optional ask)
  "同じディレクトリにもう 1 体エージェントを立ち上げる。
いまの黒板バッファの作業ディレクトリと基底名を引き継ぎ、空いている
連番（`myproj00' → `myproj01'）で新しい zellij セッションを作る。
セッションは 1 体につき 1 つなので、送信・subscribe・`zellij-send-quit'
はいずれも既存のまま各バッファ単位で効く。

コマンドはいまのバッファと同じものを引き継ぐ。ASK
（\\[universal-argument]）を付けると別のコマンド（codex など）を選べる。"
  (interactive "P")
  (let* ((name (or (zellij-send-session-name (current-buffer))
                   (user-error "zellij-send バッファ外では使えません")))
         (base (zellij-send--session-base name))
         (dir (directory-file-name (expand-file-name default-directory)))
         (current (or (zellij-send-session-command (current-buffer))
                      zellij-send-default-command))
         ;; ミニバッファは sentinel に入る前に済ませる
         (command (if ask (zellij-send--prompt-command current) current)))
    (message "セッション一覧を取得中...")
    (zellij-send-list-sessions
     (lambda (result)
       (pcase result
         (`(:ok ,sessions)
          (let ((session (zellij-send--numbered-session-name
                          base (zellij-send--taken-session-names sessions))))
            ;; sentinel の中でバッファを切り替えない（`zellij-send' と同じ約束）。
            (run-at-time 0 nil #'zellij-send--spawn-and-show session dir command)))
         (`(:failed ,reason) (message "%s" reason)))))))

(defun zellij-send--connect-existing-session (session)
  "既存 SESSION 用の黒板バッファを開く。
cwd と pane-id は zellij から取得するので、ディレクトリは尋ねない
\(`zellij-send-attach-session' 参照)。pane-id が取れなかった
場合のみ focused pane 送信になり、ターミナルでの attach が要る。
黒板が既にあれば、それを開いて subscribe を確かめるだけ。"
  (let* ((known (zellij-send-session-buffer session))
         ;; バッファ生成は同期。cwd と pane-id は後から非同期で埋まる。
         (buf (zellij-send-attach-session
               session
               (unless known
                 (lambda (buf)
                   (when (buffer-live-p buf)
                     (let ((pane-id (zellij-send-session-pane-id buf)))
                       (message "セッション [%s] に接続しました%s" session
                                (if pane-id
                                    (format " (%s)" pane-id)
                                  "（pane-id 不明: ターミナルで attach が必要です）")))))))))
    (switch-to-buffer buf)
    (goto-char (point-max))))

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
  ;; 消えたセッションの黒板を片付ける監視は、ダッシュボードを開かなくても
  ;; 動かす（`zellij-send-start-session-watch'）。黒板がすべて消えたら止まる。
  ;; 未接続のセッションへの自動接続は `zellij-send-auto-connect'（既定 nil）
  (zellij-send-start-session-watch)
  (message "セッション一覧を取得中...")
  (zellij-send-list-sessions
   (lambda (result)
     (pcase result
       (`(:ok ,sessions)
        ;; コールバックはプロセス sentinel の中で走る。sentinel 内では
        ;; quit が抑止されるため、そのままミニバッファ入力を行うと C-g が
        ;; 効かない・入力が壊れる。タイマーで sentinel を抜けてから聞く。
        (run-at-time 0 nil #'zellij-send--select-session sessions))
       (`(:failed ,reason) (message "%s" reason))))))

(provide 'zellij-send)

;;; zellij-send.el ends here
