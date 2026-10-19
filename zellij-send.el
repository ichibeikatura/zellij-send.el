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

;;; バッファ管理

(defun zellij-send--buffer-name (session)
  "SESSION に対応するバッファ名を返す。"
  (format "*ai-%s*" session))

(defun zellij-send--get-or-create-buffer (session &optional no-subscribe)
  "SESSION 用バッファを返す。なければ作成して zellij-send-mode を有効化。

subscribe を張り直すのは既存のバッファだけ。新しいバッファは呼び出し側
（`zellij-send-attach-session-async' / `zellij-send--spawn-session'）が
pane-id とコマンドを決めてから張る。ここでも張ると、ペイン検出が
2 本並んで走るうえ、新規作成ではセッションができる前に検出しに行く。
NO-SUBSCRIBE が non-nil なら既存のバッファでも張らない（自分で検出して
張る `zellij-send-attach-session-async' 用。`--connect-existing-session'
はバッファを作ってから attach を呼ぶので、そこでは既存扱いになる）。"
  (let* ((name (zellij-send--buffer-name session))
         (buf (get-buffer-create name)))
    (with-current-buffer buf
      (if (eq major-mode 'zellij-send-mode)
          ;; pane-id が未確定でも呼んでよい（ensure が特定してから張る）
          (unless no-subscribe
            (zellij-send--subscribe-ensure))
        (zellij-send-mode)
        (setq zellij-send--session session)))
    buf))

;;; セッション情報の取得（cwd・pane-id）

(defun zellij-send-attach-session-async (session &optional callback)
  "既存の SESSION 用バッファを、ユーザーに何も聞かずに用意する。
cwd は `dump-layout' から、pane-id と動いているコマンドは
`list-panes --all' を 1 回叩いて取得する（`zellij-send--detect-pane-async'）。
pane-id が取れれば attach クライアント無しでも送信できる。
用意できたら CALLBACK にバッファを渡す。"
  (let ((buf (zellij-send--get-or-create-buffer session t)))
    (zellij-send--session-cwd-async
     session
     (lambda (cwd)
       (when (and cwd (buffer-live-p buf) (file-directory-p cwd))
         (with-current-buffer buf
           (setq-local default-directory (file-name-as-directory cwd))))
       (zellij-send--detect-pane-async
        session
        (lambda (pane-id command)
          ;; コマンドを pane-id と同時に入れてから subscribe を張る。
          ;; subscribe の開始がスラッシュコマンドの先読みを呼ぶので、
          ;; `zellij-send--command' が空のままだと claude 以外のペインにも
          ;; `/' を打ってしまう
          (when (and pane-id (buffer-live-p buf))
            (with-current-buffer buf
              (setq-local zellij-send--pane-id pane-id)
              ;; **nil でも代入する**。`when command' にすると、検出に
              ;; 失敗したときに前のペインのコマンドが残り、別の CLI を
              ;; claude だと思い込む（astra のレビューで指摘）
              (setq-local zellij-send--command command)
              (zellij-send--subscribe-ensure)))
          ;; やり直しても取れなかった。黙っていると黒板が空のまま残るだけで
          ;; 理由が分からない（ダッシュボードの自動接続で踏んだ）
          (unless pane-id
            (message "[%s] のペインを特定できませんでした。黒板を閉じて（C-x k）ダッシュボードの G か M-x zellij-send で繋ぎ直してください"
                     session))
          (when callback (funcall callback buf))))))))

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

;;; セッションの作成と接続

(defun zellij-send--spawn-session (session dir &optional command)
  "SESSION という名前の detached zellij セッションを DIR に作り、ペインを起動する。
COMMAND（既定は `zellij-send-default-command'）がそのペインで動く。
attach クライアント（eat）は使わない: `zellij attach --create-background' で
セッションを作り、`zellij run' で COMMAND を起動して返る pane-id を保持し、
以後 --pane-id 指定で送受信する。
黒板バッファは同期で用意して表示し、cwd・pane-id は後から埋まる。

`zellij-send--command' はバッファを作った直後に入れる。subscribe の開始が
スラッシュコマンドの先読みを呼ぶので、claude 以外のペインに `/' を
打たないためにはペイン起動より前に確定していなければならない。"
  (let* ((command (or command zellij-send-default-command))
         (buf (zellij-send--setup-session-buffer session dir)))
    (with-current-buffer buf
      (setq-local zellij-send--command command))
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
                session dir (zellij-send--launch-command command session)
                (lambda (pane-id)
                  (if (not pane-id)
                      (message "%s の起動に失敗しました" command)
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
                    (message "セッション [%s] を作成しました (%s / %s)"
                             session command pane-id)))))))))))
    buf))

(defun zellij-send--create-new-session (known-sessions)
  "作業ディレクトリと起動するコマンドを尋ね、新しい zellij セッションを作る。
セッション名はディレクトリ名 + 2 桁の連番（`myproj00'）。
KNOWN-SESSIONS は連番を決めるための既存セッション名リスト。"
  (let* ((dir (zellij-send--prompt-session-dir))
         (command (zellij-send--prompt-command))
         (session (zellij-send--numbered-session-name
                   (file-name-nondirectory dir)
                   (zellij-send--taken-session-names known-sessions))))
    (zellij-send--spawn-session session dir command)))

(defun zellij-send-add-agent (&optional ask)
  "同じディレクトリにもう 1 体エージェントを立ち上げる。
いまの黒板バッファの作業ディレクトリと基底名を引き継ぎ、空いている
連番（`myproj00' → `myproj01'）で新しい zellij セッションを作る。
セッションは 1 体につき 1 つなので、送信・subscribe・`zellij-send-quit'
はいずれも既存のまま各バッファ単位で効く。

コマンドはいまのバッファと同じものを引き継ぐ。ASK
（\\[universal-argument]）を付けると別のコマンド（codex など）を選べる。"
  (interactive "P")
  (zellij-send--assert-session)
  (let* ((base (zellij-send--session-base zellij-send--session))
         (dir (directory-file-name (expand-file-name default-directory)))
         (current (or zellij-send--command zellij-send-default-command))
         ;; ミニバッファは sentinel に入る前に済ませる
         (command (if ask (zellij-send--prompt-command current) current)))
    (message "セッション一覧を取得中...")
    (zellij-send--list-sessions-async
     (lambda (result)
       (pcase result
         (`(:ok ,sessions)
          (let ((session (zellij-send--numbered-session-name
                          base (zellij-send--taken-session-names sessions))))
            ;; sentinel の中でバッファを切り替えない（`zellij-send' と同じ約束）。
            (run-at-time 0 nil #'zellij-send--spawn-session session dir command)))
         (`(:failed ,reason) (message "%s" reason)))))))

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
