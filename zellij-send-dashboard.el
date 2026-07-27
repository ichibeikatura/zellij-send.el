;;; zellij-send-dashboard.el --- Dashboard for zellij-send sessions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (zellij-send "0.1.0"))

;;; Commentary:

;; 複数の zellij-send セッションの状態を一覧するダッシュボード。
;;
;; 状態判定はこのファイルが自前で行う。zellij-send 本体は状態フラグを
;; 持たない（モードライン通知の撤去に伴い削除された）ため、各セッション
;; バッファの内容（zellij-send のポーリングが取得済み）から毎回算出する。
;; zellij を追加で呼ぶことはない。
;;
;;   M-x zellij-send-dashboard
;;
;; 表示される情報:
;;   Flag  ✎ = 未送信の下書きあり（＝ポーリング停止中で表示が古い）
;;         ‖ = ユーザーがクリアした（＝ポーリング停止中）
;;   St    選択待ち / 完了 / 作業中 / 待機
;;   経過  その状態になってからの時間
;;   無変化 画面内容が最後に変わってからの時間（詰まり検出用）
;;   状況   画面末尾の意味のある行（スピナー行など）

;;; Code:

(require 'zellij-send)
(require 'tabulated-list)
(require 'cl-lib)
(require 'subr-x)

(defgroup zellij-send-dashboard nil
  "Dashboard for zellij-send sessions."
  :group 'zellij-send)

(defcustom zellij-send-dashboard-refresh-interval 1.0
  "ダッシュボードの再描画間隔（秒）。0 で自動更新なし（g で手動更新）。"
  :type 'number
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-buffer-name "*zellij-dashboard*"
  "ダッシュボードのバッファ名。"
  :type 'string
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-working-regexp "esc to interrupt"
  "AI が処理中であることを示す、画面上のスピナー行の正規表現。
Claude Code は処理中に `✳ Frobnicating… (12s · esc to interrupt)' の
ような行を出す。これが消えたら処理が終わったとみなす。"
  :type 'regexp
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-noise-regexps
  '("\\`[[:space:]]*\\'"
    "\\`[─│╭╮╰╯━┃┏┓┗┛[:space:]]*\\'"
    "\\`❯[[:space:]]*\\'"
    "shortcuts"
    "bypass permissions"
    "^[[:space:]]*⏵⏵")
  "「状況」列を拾うときに読み飛ばす行の正規表現。
Claude Code の入力ボックスやフッタ行を除外し、
スピナー行（例: `✳ Frobnicating… (12s · esc to interrupt)'）を拾うため。"
  :type '(repeat regexp)
  :group 'zellij-send-dashboard)

(defface zellij-send-dashboard-prompt-face
  '((t :inherit warning :weight bold))
  "選択肢待ちのセッションに使う face。")

(defface zellij-send-dashboard-done-face
  '((t :inherit success :weight bold))
  "応答完了のセッションに使う face。")

(defface zellij-send-dashboard-working-face
  '((t :inherit font-lock-keyword-face))
  "作業中のセッションに使う face。")

(defface zellij-send-dashboard-idle-face
  '((t :inherit shadow))
  "待機中のセッションに使う face。")

(defvar zellij-send-dashboard--timer nil
  "再描画タイマー。")

(defvar zellij-send-dashboard--state (make-hash-table :test #'equal)
  "セッション名 -> plist (:tick :changed-at :status :status-at :done)。
状態遷移と画面変化の時刻、および「作業中→完了」の遷移を
覚えておくためのもの。")

(defconst zellij-send-dashboard--status-alist
  '((prompt  "❓ 選択待ち" zellij-send-dashboard-prompt-face  0)
    (done    "☝ 完了"     zellij-send-dashboard-done-face     1)
    (working "✍ 作業中"   zellij-send-dashboard-working-face  2)
    (idle    "· 待機"     zellij-send-dashboard-idle-face     3))
  "状態シンボル -> (ラベル face ソート優先度)。")


;;; セッションの収集と状態判定

(defun zellij-send-dashboard--session-buffers ()
  "生きている zellij-send バッファのリストを返す。"
  (cl-remove-if-not
   (lambda (buf)
     (and (buffer-live-p buf)
          (eq (buffer-local-value 'major-mode buf) 'zellij-send-mode)
          (buffer-local-value 'zellij-send--session buf)))
   (buffer-list)))

(defun zellij-send-dashboard--working-p (buf)
  "BUF の画面にスピナー行があれば non-nil（＝AI が処理中）。"
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-max))
      ;; スピナーは画面下部にしか出ない。全体を毎秒走査しないよう末尾に限定する。
      (let ((beg (max (point-min) (- (point-max) 4000))))
        (re-search-backward zellij-send-dashboard-working-regexp beg t)))))

(defun zellij-send-dashboard--prompt-p (buf)
  "BUF に選択肢プロンプトがあれば non-nil。"
  (with-current-buffer buf
    (zellij-send--detect-prompt)))

(defun zellij-send-dashboard--status (buf session)
  "BUF（SESSION）の状態シンボルを返す。
判定は画面内容から毎回行う（本体は状態フラグを持たない）。
`working' から `working' でなくなった瞬間に `done' を立て、
そのセッションのバッファをユーザーが見た時点で `done' を下ろす。"
  (let* ((st (gethash session zellij-send-dashboard--state))
         (was-working (eq (plist-get st :status) 'working))
         (working (zellij-send-dashboard--working-p buf))
         (done (plist-get st :done)))
    (cond
     ;; 画面を見た＝確認済みとみなし、完了通知を下ろす
     ((get-buffer-window buf t)
      (when st (puthash session (plist-put st :done nil)
                        zellij-send-dashboard--state))
      (cond ((zellij-send-dashboard--prompt-p buf) 'prompt)
            (working 'working)
            (t 'idle)))
     ((zellij-send-dashboard--prompt-p buf) 'prompt)
     (working 'working)
     ((or done was-working)
      (when st (puthash session (plist-put st :done t)
                        zellij-send-dashboard--state))
      'done)
     (t 'idle))))

(defun zellij-send-dashboard--flag (buf)
  "BUF の表示が更新停止中かどうかを表す印を返す。
zellij-send のポーリングは buffer-modified-p と user-cleared のとき
更新をスキップするため、その場合は表示が古い旨を明示する。"
  (with-current-buffer buf
    (cond (zellij-send--user-cleared
           (propertize "‖" 'face 'shadow
                       'help-echo "クリア済み: ポーリング停止中"))
          ((buffer-modified-p)
           (propertize "✎" 'face 'font-lock-string-face
                       'help-echo "未送信の下書きあり: ポーリング停止中"))
          (t " "))))

(defun zellij-send-dashboard--touch (session tick status)
  "SESSION の TICK と STATUS の変化時刻を記録し、plist を返す。"
  (let* ((now (float-time))
         (st (gethash session zellij-send-dashboard--state)))
    (if (null st)
        (setq st (list :tick tick :changed-at now :status status :status-at now))
      (unless (equal (plist-get st :tick) tick)
        (setq st (plist-put st :tick tick))
        (setq st (plist-put st :changed-at now)))
      (unless (eq (plist-get st :status) status)
        (setq st (plist-put st :status status))
        (setq st (plist-put st :status-at now))))
    (puthash session st zellij-send-dashboard--state)
    st))

(defun zellij-send-dashboard--gc-state (live-sessions)
  "LIVE-SESSIONS に無いセッションの記録を捨てる。"
  (let (dead)
    (maphash (lambda (k _v)
               (unless (member k live-sessions) (push k dead)))
             zellij-send-dashboard--state)
    (dolist (k dead) (remhash k zellij-send-dashboard--state))))


;;; 表示用の整形

(defun zellij-send-dashboard--fmt-elapsed (secs)
  "SECS 秒を短い文字列にする。"
  (let ((s (floor (max 0 secs))))
    (cond ((< s 60)   (format "%ds" s))
          ((< s 3600) (format "%dm%02d" (/ s 60) (% s 60)))
          (t          (format "%dh%02d" (/ s 3600) (% (/ s 60) 60))))))

(defun zellij-send-dashboard--noise-p (line)
  "LINE が読み飛ばすべき行なら non-nil。"
  (cl-some (lambda (re) (string-match-p re line))
           zellij-send-dashboard-noise-regexps))

(defun zellij-send-dashboard--tail-line (buf)
  "BUF の画面末尾から、意味のありそうな行を 1 行拾う。"
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-max))
      (let ((line nil) (guard 40))
        (while (and (null line) (> guard 0) (not (bobp)))
          (cl-decf guard)
          (forward-line -1)
          (let ((s (string-trim (buffer-substring-no-properties
                                 (line-beginning-position)
                                 (line-end-position)))))
            (unless (zellij-send-dashboard--noise-p s)
              (setq line s))))
        (truncate-string-to-width (or line "") 70 nil nil "…")))))

(defun zellij-send-dashboard--status-cell (status)
  "STATUS のラベル文字列（face 付き）を返す。"
  (let ((spec (alist-get status zellij-send-dashboard--status-alist)))
    (propertize (nth 0 spec) 'face (nth 1 spec))))

(defun zellij-send-dashboard--priority (status)
  "STATUS のソート優先度（小さいほど要対応）。不明な STATUS は最下位。"
  (or (nth 2 (alist-get status zellij-send-dashboard--status-alist)) 99))


;;; エントリ生成

(defun zellij-send-dashboard--entries ()
  "tabulated-list 用のエントリを、要対応順に並べて返す。"
  (let ((now (float-time))
        (bufs (zellij-send-dashboard--session-buffers))
        entries sessions)
    (dolist (buf bufs)
      (let* ((session (buffer-local-value 'zellij-send--session buf))
             (status (zellij-send-dashboard--status buf session))
             (st (zellij-send-dashboard--touch
                  session (buffer-chars-modified-tick buf) status)))
        (push session sessions)
        (push (list buf
                    (vector (zellij-send-dashboard--flag buf)
                            (zellij-send-dashboard--status-cell status)
                            session
                            (zellij-send-dashboard--fmt-elapsed
                             (- now (plist-get st :status-at)))
                            (zellij-send-dashboard--fmt-elapsed
                             (- now (plist-get st :changed-at)))
                            (zellij-send-dashboard--tail-line buf)))
              entries)))
    (zellij-send-dashboard--gc-state sessions)
    ;; 状態は算出済み（1 行あたり 1 回だけ判定する）。ソートは
    ;; 記録済みの :status を使い、判定を再実行しない。
    (sort (nreverse entries)
          (lambda (a b)
            (let* ((sa (aref (cadr a) 2))
                   (sb (aref (cadr b) 2))
                   (pa (zellij-send-dashboard--priority
                        (plist-get (gethash sa zellij-send-dashboard--state)
                                   :status)))
                   (pb (zellij-send-dashboard--priority
                        (plist-get (gethash sb zellij-send-dashboard--state)
                                   :status))))
              (if (= pa pb)
                  (string< sa sb)
                (< pa pb)))))))

(defun zellij-send-dashboard-refresh ()
  "ダッシュボードを再描画する。"
  (interactive)
  (setq tabulated-list-entries (zellij-send-dashboard--entries))
  (tabulated-list-print t t)
  (when (null tabulated-list-entries)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert "\n  セッションがありません（M-x zellij-send で開始）\n")))))


;;; 操作

(defun zellij-send-dashboard--buffer-at-point ()
  "カーソル行のセッションバッファを返す。無ければエラー。"
  (let ((buf (tabulated-list-get-id)))
    (unless (buffer-live-p buf)
      (user-error "セッションバッファがありません"))
    buf))

(defun zellij-send-dashboard-visit ()
  "カーソル行のセッションバッファに移動する。"
  (interactive)
  (pop-to-buffer (zellij-send-dashboard--buffer-at-point)))

(defun zellij-send-dashboard-visit-other-window ()
  "カーソル行のセッションを別ウィンドウに表示し、ダッシュボードに留まる。"
  (interactive)
  (display-buffer (zellij-send-dashboard--buffer-at-point)))

(defun zellij-send-dashboard-reply ()
  "カーソル行のセッションに対して返信バッファを開く。"
  (interactive)
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-reply)))

(defun zellij-send-dashboard-show-response ()
  "カーソル行のセッションの画面を手動で取得する。"
  (interactive)
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-show-response)))

(defun zellij-send-dashboard--send-choice (n)
  "カーソル行のセッションが選択肢待ちなら N を送る。"
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (unless (zellij-send--detect-prompt)
      (user-error "[%s] は選択肢待ちではありません" zellij-send--session))
    (let ((session zellij-send--session))
      ;; `zellij-send--send' はカレントバッファの pane-id を見るため、
      ;; セッションバッファをカレントにしたまま呼ぶ必要がある。
      (zellij-send--send session (number-to-string n)
                         (lambda (ok)
                           (when ok
                             (message "選択 %d を送信 → [%s]" n session))))
      (zellij-send--clear-prompt-highlight))))

(defun zellij-send-dashboard-select-1 ()
  "カーソル行のセッションに選択肢 1 を送る。"
  (interactive) (zellij-send-dashboard--send-choice 1))

(defun zellij-send-dashboard-select-2 ()
  "カーソル行のセッションに選択肢 2 を送る。"
  (interactive) (zellij-send-dashboard--send-choice 2))

(defun zellij-send-dashboard-select-3 ()
  "カーソル行のセッションに選択肢 3 を送る。"
  (interactive) (zellij-send-dashboard--send-choice 3))

(defun zellij-send-dashboard-compact ()
  "カーソル行のセッションに /compact を送る。"
  (interactive)
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-compact)))

(defun zellij-send-dashboard-kill-session ()
  "カーソル行のセッションを削除する（確認あり）。"
  (interactive)
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-quit)))

(defun zellij-send-dashboard-open-log ()
  "カーソル行のセッションの出力ログを開く。"
  (interactive)
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-open-log)))


;;; タイマー

(defun zellij-send-dashboard--tick ()
  "タイマーコールバック。表示中のときだけ再描画する。"
  (let ((buf (get-buffer zellij-send-dashboard-buffer-name)))
    (if (not (buffer-live-p buf))
        (zellij-send-dashboard--stop-timer)
      (when (get-buffer-window buf t)
        (with-demoted-errors "zellij-send-dashboard: %S"
          (with-current-buffer buf
            (zellij-send-dashboard-refresh)))))))

(defun zellij-send-dashboard--start-timer ()
  "再描画タイマーを開始する。"
  (when (and (> zellij-send-dashboard-refresh-interval 0)
             (null zellij-send-dashboard--timer))
    (setq zellij-send-dashboard--timer
          (run-at-time zellij-send-dashboard-refresh-interval
                       zellij-send-dashboard-refresh-interval
                       #'zellij-send-dashboard--tick))))

(defun zellij-send-dashboard--stop-timer ()
  "再描画タイマーを止める。"
  (when zellij-send-dashboard--timer
    (cancel-timer zellij-send-dashboard--timer)
    (setq zellij-send-dashboard--timer nil)))


;;; メジャーモード

(defvar zellij-send-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'zellij-send-dashboard-visit)
    (define-key map (kbd "o")   #'zellij-send-dashboard-visit-other-window)
    (define-key map (kbd "e")   #'zellij-send-dashboard-reply)
    (define-key map (kbd "a")   #'zellij-send-dashboard-show-response)
    (define-key map (kbd "l")   #'zellij-send-dashboard-open-log)
    (define-key map (kbd "c")   #'zellij-send-dashboard-compact)
    (define-key map (kbd "k")   #'zellij-send-dashboard-kill-session)
    (define-key map (kbd "1")   #'zellij-send-dashboard-select-1)
    (define-key map (kbd "2")   #'zellij-send-dashboard-select-2)
    (define-key map (kbd "3")   #'zellij-send-dashboard-select-3)
    (define-key map (kbd "g")   #'zellij-send-dashboard-refresh)
    map)
  "zellij-send-dashboard-mode のキーマップ。")

(define-derived-mode zellij-send-dashboard-mode tabulated-list-mode "ZS-Dash"
  "zellij-send セッションの状態一覧。

\\{zellij-send-dashboard-mode-map}"
  (setq tabulated-list-format
        [("" 2 nil)
         ("状態" 12 nil)
         ("セッション" 18 t)
         ("経過" 7 nil)
         ("無変化" 8 nil)
         ("状況" 0 nil)])
  (setq tabulated-list-padding 1)
  (setq header-line-format
        " RET:移動 o:別窓 e:返信 1/2/3:選択 a:取得 l:ログ c:圧縮 k:削除 g:更新")
  (tabulated-list-init-header)
  (add-hook 'kill-buffer-hook #'zellij-send-dashboard--stop-timer nil t))

;;;###autoload
(defun zellij-send-dashboard ()
  "zellij-send セッションのダッシュボードを開く。"
  (interactive)
  (let ((buf (get-buffer-create zellij-send-dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'zellij-send-dashboard-mode)
        (zellij-send-dashboard-mode))
      (zellij-send-dashboard-refresh))
    (pop-to-buffer buf)
    (zellij-send-dashboard--start-timer)))

(provide 'zellij-send-dashboard)

;;; zellij-send-dashboard.el ends here
