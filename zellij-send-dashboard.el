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

(defcustom zellij-send-dashboard-refresh-interval 3.0
  "ダッシュボードの再描画間隔（秒）。0 で自動更新なし（g で手動更新）。
短すぎると行を選ぶ操作の途中で再描画が入り、カーソルが動かしにくくなる。"
  :type 'number
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-buffer-name "*zellij-dashboard*"
  "ダッシュボードのバッファ名。"
  :type 'string
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-display-action
  '((display-buffer-reuse-window display-buffer-below-selected)
    (window-height . fit-window-to-buffer))
  "ダッシュボードを表示するときの `display-buffer' アクション。
セッションは数個しかないので、既定では下部に内容ぴったりの高さで開く。
フレーム全体で開きたい場合は nil にする（`pop-to-buffer' の既定に戻る）。"
  :type 'sexp
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-fit-window t
  "non-nil なら再描画のたびにウィンドウ高さを内容に合わせる。"
  :type 'boolean
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-max-height 16
  "`zellij-send-dashboard-fit-window' が使うウィンドウの最大行数。"
  :type 'integer
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-tail-width 40
  "「状況」列に表示する画面末尾行の最大幅（桁）。"
  :type 'integer
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

(defcustom zellij-send-dashboard-auto-connect t
  "non-nil なら起動時に、まだバッファの無い zellij セッションへ自動接続する。
`zellij list-sessions' の各セッションについて cwd と pane-id を取得し
（`zellij-send-attach-session-async'）、黒板バッファを用意する。
ユーザーには何も尋ねない。"
  :type 'boolean
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-show-usage t
  "non-nil ならダッシュボードに Claude の使用状況（/usage 相当）を表示する。"
  :type 'boolean
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-usage-file
  (expand-file-name "~/.claude/zellij-send-usage.json")
  "Claude Code の statusLine フックが書き出す使用状況 JSON のパス。
`/usage' の情報（`rate_limits.five_hour' / `seven_day' の
`used_percentage' と `resets_at'）は statusLine フックの stdin JSON
としてのみ供給される。README の手順でフックを登録すること。"
  :type 'file
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-usage-bar-width 24
  "使用状況バーの表示幅（桁）。"
  :type 'integer
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-usage-timezone nil
  "使用状況のリセット時刻に添えるタイムゾーン表記。
nil なら環境変数 TZ、それも無ければ `%Z'（例: JST）を使う。"
  :type '(choice (const :tag "自動" nil) string)
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-remote-control-timeout 40.0
  "Remote Control の画面が出るまで待つ上限秒数。
claude.ai への接続に 10 秒以上かかることがあるため、固定待ちではなく
この時間まで画面をポーリングする。"
  :type 'number
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-remote-control-poll 1.5
  "Remote Control 待ちのポーリング間隔（秒）。"
  :type 'number
  :group 'zellij-send-dashboard)

(defface zellij-send-dashboard-usage-low-face
  '((t :inherit success))
  "使用率が低いときのバーの face。")

(defface zellij-send-dashboard-usage-mid-face
  '((t :inherit warning))
  "使用率が中程度のときのバーの face。")

(defface zellij-send-dashboard-usage-high-face
  '((t :inherit error))
  "使用率が高いときのバーの face。")

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
        (truncate-string-to-width (or line "")
                                  zellij-send-dashboard-tail-width nil nil "…")))))

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

;;; 使用状況（/usage 相当）

;; Claude Code の /usage は TUI 内でしか実行できず、CLI にも
;; サブコマンドが無い。レート制限の情報は statusLine フックの stdin
;; JSON としてのみ供給されるため、フック側でその JSON をファイルに
;; 保存し、ここでは読むだけにする（zellij も claude も呼ばない）。

(defconst zellij-send-dashboard--bar-partials
  ["" "▏" "▎" "▍" "▌" "▋" "▊" "▉"]
  "バー末尾に使う 1/8 刻みの部分ブロック。")

(defun zellij-send-dashboard--read-usage ()
  "使用状況 JSON を読み、(DATA . MTIME) を返す。読めなければ nil。"
  (let ((file zellij-send-dashboard-usage-file))
    (when (and file (file-readable-p file))
      (with-demoted-errors "zellij-send-dashboard: usage 読み込み失敗 %S"
        (let ((mtime (file-attribute-modification-time
                      (file-attributes file))))
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (cons (json-parse-buffer :object-type 'alist
                                     :null-object nil
                                     :false-object nil)
                  mtime)))))))

(defun zellij-send-dashboard--usage-face (pct)
  "PCT に応じたバーの face を返す。"
  (cond ((>= pct 80) 'zellij-send-dashboard-usage-high-face)
        ((>= pct 50) 'zellij-send-dashboard-usage-mid-face)
        (t           'zellij-send-dashboard-usage-low-face)))

(defun zellij-send-dashboard--bar (pct)
  "PCT（0-100）を表すバーを返す。
幅は `zellij-send-dashboard-usage-bar-width' 桁。ブロック文字（█ など）は
East Asian Ambiguous のため環境によっては 1 文字 2 桁で表示される。
文字数ではなく桁数で割り当てないとバーが 2 倍の長さになるので、
`string-width' で 1 ブロックあたりの桁数を測ってから計算する。"
  (let* ((width zellij-send-dashboard-usage-bar-width)
         (cell (max 1 (string-width "█")))
         (blocks (max 1 (/ width cell)))
         (pct (min 100 (max 0 (or pct 0))))
         (eighths (round (* (/ pct 100.0) blocks 8)))
         (full (/ eighths 8))
         (rest (% eighths 8))
         (bar (concat (make-string full ?█)
                      (aref zellij-send-dashboard--bar-partials rest))))
    (concat (propertize bar 'face (zellij-send-dashboard--usage-face pct))
            (make-string (max 0 (- width (string-width bar))) ?\s))))

(defun zellij-send-dashboard--tz-label ()
  "リセット時刻に添えるタイムゾーン表記を返す。"
  (or zellij-send-dashboard-usage-timezone
      (getenv "TZ")
      (format-time-string "%Z")))

(defconst zellij-send-dashboard--month-names
  ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
   "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]
  "月の英略称。`format-time-string' の %b はロケール依存で
日本語環境では \" 7\" のようになるため、自前で持つ。")

(defun zellij-send-dashboard--fmt-reset (epoch)
  "EPOCH（Unix 秒）を `/usage' と同じ書式のリセット時刻表記にする。
当日ならば時刻のみ、翌日以降は日付を添える。
am/pm と月名はロケールに依存しないよう自前で組み立てる。"
  (when (numberp epoch)
    (let* ((time (seconds-to-time epoch))
           (dec (decode-time time))
           (minute (nth 1 dec))
           (hour (nth 2 dec))
           (h12 (if (zerop (% hour 12)) 12 (% hour 12)))
           (ampm (if (< hour 12) "am" "pm"))
           ;; 分が 00 なら /usage と同じく分を省く（例: "9pm"）
           (clock (if (zerop minute)
                      (format "%d%s" h12 ampm)
                    (format "%d:%02d%s" h12 minute ampm)))
           (same-day (equal (format-time-string "%F" time)
                            (format-time-string "%F"))))
      (format "Resets %s (%s)"
              (if same-day
                  clock
                (format "%s %d at %s"
                        (aref zellij-send-dashboard--month-names
                              (1- (nth 4 dec)))
                        (nth 3 dec) clock))
              (zellij-send-dashboard--tz-label)))))

(defconst zellij-send-dashboard--usage-labels
  '((five_hour . "Current session")
    (seven_day . "Current week"))
  "レート制限の種別 -> 表示ラベル（`/usage' の見出しに合わせる）。")

(defun zellij-send-dashboard--insert-usage-line (key limit width)
  "LIMIT（alist）を 1 行で挿入する。KEY はラベル、WIDTH はラベル幅。
「ラベル:バー NN% used Resets ...」の 1 行にまとめる（縦を使わない）。"
  (let ((pct (alist-get 'used_percentage limit))
        (resets (alist-get 'resets_at limit))
        (label (alist-get key zellij-send-dashboard--usage-labels)))
    (when (numberp pct)
      ;; `format' に %-*s は無いので桁幅で自前に揃える
      (insert (propertize
               (concat label
                       (make-string (max 0 (- width (string-width label))) ?\s)
                       ":")
               'face 'bold)
              (zellij-send-dashboard--bar pct)
              (format " %3d%% used" (round pct)))
      (when-let* ((line (zellij-send-dashboard--fmt-reset resets)))
        (insert " " (propertize line 'face 'shadow)))
      (insert "\n"))))

(defun zellij-send-dashboard--insert-usage ()
  "使用状況をバッファ末尾に挿入する。"
  (let* ((cache (zellij-send-dashboard--read-usage))
         (data (car cache))
         (limits (and data (alist-get 'rate_limits data))))
    (if (null limits)
        (insert (propertize
                 (if data
                     "使用状況: レート制限の情報がありません（Claude サブスク以外、または API 応答前）\n"
                   (format "使用状況: %s がありません（README の statusLine フック設定を参照）\n"
                           (abbreviate-file-name
                            zellij-send-dashboard-usage-file)))
                 'face 'shadow))
      (insert (propertize
               (format "── 使用状況 ─ %s前の記録 %s\n"
                       (zellij-send-dashboard--fmt-elapsed
                        (float-time (time-since (cdr cache))))
                       (make-string 13 ?─))
               'face 'shadow))
      (let ((width (apply #'max (mapcar (lambda (c) (string-width (cdr c)))
                                        zellij-send-dashboard--usage-labels))))
        (dolist (key '(five_hour seven_day))
          (zellij-send-dashboard--insert-usage-line
           key (alist-get key limits) width))))))

(defun zellij-send-dashboard-refresh ()
  "ダッシュボードを再描画する。"
  (interactive)
  (setq tabulated-list-entries (zellij-send-dashboard--entries))
  (tabulated-list-print t t)
  ;; 追記は表の後ろに限る。表より前に入れると、カーソルが使用状況の行に
  ;; あるときに `tabulated-list-print' が行を特定できず先頭に戻ってしまう。
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (when (null tabulated-list-entries)
        (insert "\n  セッションがありません（M-x zellij-send で開始）\n"))
      (when zellij-send-dashboard-show-usage
        (zellij-send-dashboard--insert-usage))))
  (zellij-send-dashboard--fit-window))

(defun zellij-send-dashboard--fit-window ()
  "ダッシュボードのウィンドウ高さを内容に合わせる。
セッションは数個しかないので、既定では画面を占有しない。"
  (when zellij-send-dashboard-fit-window
    (let ((win (get-buffer-window (current-buffer))))
      (when (and (window-live-p win)
                 (not (eq win (frame-root-window win))))
        (with-demoted-errors "zellij-send-dashboard: %S"
          (fit-window-to-buffer win zellij-send-dashboard-max-height))))))


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

;;; Remote Control（QR 表示）

;; Claude Code の Remote Control はセッションを claude.ai / モバイルアプリに
;; 橋渡しする。QR は Claude Code 自身が半角ブロック文字（▀▄█）で描くので、
;; dump-screen した文字列をそのまま貼れば QR 生成器は要らない。
;; ただしブロック文字は East Asian Ambiguous で char-width が 2 になる環境が
;; あり、そのままだと QR が横に 2 倍伸びて読み取れない。表示用バッファでは
;; char-width-table をバッファローカルに差し替えて 1 桁にする。

(defconst zellij-send-dashboard--qr-chars
  '(?█ ?▀ ?▄ ?▌ ?▐ ?░ ?▒ ?▓)
  "QR の描画に使われるブロック文字。表示時に幅 1 桁へ矯正する。")

(defun zellij-send-dashboard--send-keys (session bytes callback)
  "SESSION の対象ペインに BYTES（数値リスト）をキー入力として送る。
カレントバッファの `zellij-send--pane-id' を使うので、
必ずセッションバッファをカレントにして呼ぶこと。"
  (zellij-send--zellij-async
   (append (list "--session" session "action" "write")
           (zellij-send--pane-args)
           (list "--")
           (mapcar #'number-to-string bytes))
   callback))

(defun zellij-send-dashboard--extract-qr (screen)
  "SCREEN からブロック文字だけで構成された連続行（QR）を返す。無ければ nil。"
  (let ((qr (seq-filter
             (lambda (line)
               (let ((s (string-trim line)))
                 (and (not (string-empty-p s))
                      (string-match-p "[█▀▄]" s)
                      ;; ブロック文字と空白だけの行に限る（本文行を拾わない）
                      (not (string-match-p "[[:alnum:]]" s)))))
             (split-string screen "\n"))))
    (when (> (length qr) 4) qr)))

(defun zellij-send-dashboard--extract-url (screen)
  "SCREEN から Remote Control のセッション URL を返す。無ければ nil。
URL はペイン幅で折り返されるため、行頭の空白ごと改行を畳んでから探す。"
  (let ((joined (replace-regexp-in-string "[ \t]*\n[ \t]*" "" screen)))
    (when (string-match "https://claude\\.ai/code/[A-Za-z0-9_-]+" joined)
      (match-string 0 joined))))

(defun zellij-send-dashboard--show-qr (session screen)
  "SESSION の SCREEN から QR と URL を取り出して専用バッファに表示する。"
  (let ((qr (zellij-send-dashboard--extract-qr screen))
        (url (zellij-send-dashboard--extract-url screen))
        (buf (get-buffer-create (format "*zellij-qr-%s*" session))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        ;; ブロック文字を 1 桁にする（2 桁のままだと QR が横に伸びて読めない）
        (setq-local char-width-table (copy-sequence char-width-table))
        (dolist (c zellij-send-dashboard--qr-chars)
          (set-char-table-range char-width-table (cons c c) 1))
        (setq-local line-spacing 0)
        (setq-local cursor-type nil)
        (insert (propertize (format " Remote Control — [%s]\n\n" session)
                            'face 'bold))
        (if qr
            (insert (mapconcat #'identity qr "\n") "\n\n")
          (insert (propertize " QR コードを取得できませんでした。\n\n"
                              'face 'warning)))
        (if url
            (insert " " (propertize url 'face 'link) "\n\n"
                    (propertize " スマホでスキャンするか、上の URL を開いてください。\n"
                                'face 'shadow))
          (insert (propertize " URL も取得できませんでした。ペインを直接確認してください。\n"
                              'face 'warning)))
        (goto-char (point-min))))
    (display-buffer buf)
    (when url (kill-new url) (message "URL をキルリングにコピーしました"))))

(defun zellij-send-dashboard--wait-for-screen (buf session pred deadline on-ok on-timeout)
  "SESSION の画面が PRED を満たすまでポーリングする。
満たしたら ON-OK に画面文字列を渡して呼ぶ。DEADLINE（`float-time' 値）を
過ぎたら ON-TIMEOUT に最後の画面を渡して呼ぶ。
claude.ai への接続時間は読めないので固定待ちにはしない。"
  (with-current-buffer buf
    (zellij-send--dump-screen-async
     session
     (lambda (screen)
       (cond
        ((and screen (funcall pred screen)) (funcall on-ok screen))
        ((> (float-time) deadline) (funcall on-timeout screen))
        (t
         (run-at-time zellij-send-dashboard-remote-control-poll nil
                      #'zellij-send-dashboard--wait-for-screen
                      buf session pred deadline on-ok on-timeout)))))))

(defun zellij-send-dashboard--deadline ()
  "Remote Control 待ちの締切時刻を返す。"
  (+ (float-time) zellij-send-dashboard-remote-control-timeout))

(defun zellij-send-dashboard--qr-step-capture (buf session)
  "QR が描かれるまで待ち、バッファに映してからペインを Esc で戻す。"
  (zellij-send-dashboard--wait-for-screen
   buf session
   (lambda (screen) (zellij-send-dashboard--extract-qr screen))
   (zellij-send-dashboard--deadline)
   (lambda (screen)
     (zellij-send-dashboard--show-qr session screen)
     ;; ペインをプロンプトに戻す（メニューに留まると以後の送信が壊れる）
     (with-current-buffer buf
       (zellij-send-dashboard--send-keys session '(27) #'ignore)))
   (lambda (screen)
     (message "QR コードの表示を待ちましたが出ませんでした")
     (zellij-send-dashboard--show-qr session (or screen ""))
     (with-current-buffer buf
       (zellij-send-dashboard--send-keys session '(27) #'ignore)))))

(defconst zellij-send-dashboard--rc-menu-items
  '("Disconnect this session" "Show QR code" "Hide QR code" "Continue")
  "Remote Control メニューの項目ラベル。
項目の説明文は折り返して複数行になるため、**行数ではなく項目数**で
カーソル移動量を数える必要がある（行数で数えると Show QR code を
通り越して Disconnect this session を選んでしまう）。")

(defun zellij-send-dashboard--qr-menu-visible-p (screen)
  "SCREEN に Remote Control のメニューが出ていれば non-nil。"
  (string-match-p "Show QR code\\|Hide QR code" screen))

(defun zellij-send-dashboard--rc-menu-items (screen)
  "SCREEN のメニュー項目を (ラベル . 選択中か) のリストで順に返す。"
  (delq nil
        (mapcar
         (lambda (line)
           (let ((label (seq-find (lambda (it) (string-match-p (regexp-quote it) line))
                                  zellij-send-dashboard--rc-menu-items)))
             (when label
               (cons label (string-match-p "^[[:space:]]*❯" line)))))
         (split-string screen "\n"))))

(defun zellij-send-dashboard--rc-selected-p (screen label)
  "SCREEN のメニューで LABEL が選択中なら non-nil。"
  (let ((item (assoc label (zellij-send-dashboard--rc-menu-items screen))))
    (and item (cdr item))))

(defun zellij-send-dashboard--qr-step-menu (buf session)
  "Remote Control のメニューが出るまで待ち、「Show QR code」を選ぶ。"
  (zellij-send-dashboard--wait-for-screen
   buf session #'zellij-send-dashboard--qr-menu-visible-p
   (zellij-send-dashboard--deadline)
   (lambda (screen)
     (let* ((items (zellij-send-dashboard--rc-menu-items screen))
            (labels (mapcar #'car items))
            (qr-idx (seq-position labels "Show QR code"))
            (cur-idx (seq-position items nil (lambda (it _) (cdr it)))))
       (cond
        ;; 「Hide QR code」＝すでに QR が出ている。そのまま取り込む
        ((null qr-idx) (zellij-send-dashboard--qr-step-capture buf session))
        ((null cur-idx)
         (message "メニューの選択位置が読めませんでした。ペインを直接確認してください")
         (zellij-send-dashboard--show-qr session screen))
        ((= cur-idx qr-idx) (zellij-send-dashboard--qr-confirm-and-enter buf session))
        (t
         (let* ((delta (- cur-idx qr-idx))
                ;; ↑ = ESC [ A、↓ = ESC [ B
                (key (if (> delta 0) '(27 91 65) '(27 91 66)))
                (keys (apply #'append (make-list (abs delta) key))))
           (with-current-buffer buf
             (zellij-send-dashboard--send-keys
              session keys
              (lambda (_)
                (zellij-send-dashboard--qr-confirm-and-enter buf session)))))))))
   (lambda (screen)
     (message "Remote Control の画面が出ませんでした（%.0f 秒待機）。ペインを直接確認してください"
              zellij-send-dashboard-remote-control-timeout)
     (when screen
       (zellij-send-dashboard--show-qr session screen)))))

(defun zellij-send-dashboard--qr-confirm-and-enter (buf session)
  "「Show QR code」が選択されていることを確認してから Enter を送る。
確認せずに Enter を送ると、ずれていた場合に
「Disconnect this session」を実行してしまうため。"
  (zellij-send-dashboard--wait-for-screen
   buf session
   (lambda (screen)
     (zellij-send-dashboard--rc-selected-p screen "Show QR code"))
   (+ (float-time) 6.0)
   (lambda (_screen)
     (with-current-buffer buf
       (zellij-send-dashboard--send-keys
        session '(13)
        (lambda (_) (zellij-send-dashboard--qr-step-capture buf session)))))
   (lambda (_screen)
     (message "「Show QR code」を選択できませんでした。何も実行せず中止します")
     (with-current-buffer buf
       (zellij-send-dashboard--send-keys session '(27) #'ignore)))))

(defun zellij-send-dashboard-remote-control ()
  "カーソル行のセッションを Remote Control に接続し、QR コードを表示する。
セッションが claude.ai / Claude モバイルアプリから操作できるようになる。
対象ペインに `/remote-control' を打ち込むため、待機中のセッションのみ
許可する（作業中に割り込まないようにするため）。"
  (interactive)
  (let* ((buf (zellij-send-dashboard--buffer-at-point))
         (session (buffer-local-value 'zellij-send--session buf))
         (status (plist-get (gethash session zellij-send-dashboard--state)
                            :status)))
    (unless (eq status 'idle)
      (user-error "[%s] は待機中ではありません。作業が終わってから実行してください"
                  session))
    ;; ローカルのセッションを claude.ai 側に露出させる操作なので必ず確認する
    (unless (yes-or-no-p
             (format "[%s] を Remote Control に接続しますか?（claude.ai / モバイルアプリから操作できるようになります） "
                     session))
      (user-error "キャンセルしました"))
    (with-current-buffer buf
      (message "[%s] を Remote Control に接続中..." session)
      (zellij-send--send
       session "/remote-control"
       (lambda (ok)
         (when ok
           (zellij-send-dashboard--qr-step-menu buf session)))))))

(defun zellij-send-dashboard-quit-idle-session ()
  "カーソル行のセッションが待機中なら終了する（確認あり）。
作業中・選択待ち・完了のセッションは誤終了を防ぐため拒否する
（それでも終了したい場合は k）。"
  (interactive)
  (let* ((buf (zellij-send-dashboard--buffer-at-point))
         (session (buffer-local-value 'zellij-send--session buf))
         (status (plist-get (gethash session zellij-send-dashboard--state)
                            :status)))
    (unless (eq status 'idle)
      (user-error "[%s] は待機中ではありません（%s）。強制終了するなら k"
                  session
                  (nth 0 (alist-get status
                                    zellij-send-dashboard--status-alist))))
    (with-current-buffer buf
      (zellij-send-quit))))

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
    (define-key map (kbd "Q")   #'zellij-send-dashboard-quit-idle-session)
    (define-key map (kbd "r")   #'zellij-send-dashboard-remote-control)
    (define-key map (kbd "1")   #'zellij-send-dashboard-select-1)
    (define-key map (kbd "2")   #'zellij-send-dashboard-select-2)
    (define-key map (kbd "3")   #'zellij-send-dashboard-select-3)
    (define-key map (kbd "g")   #'zellij-send-dashboard-refresh)
    (define-key map (kbd "G")   #'zellij-send-dashboard-connect-all)
    map)
  "zellij-send-dashboard-mode のキーマップ。")

(define-derived-mode zellij-send-dashboard-mode tabulated-list-mode "ZS-Dash"
  "zellij-send セッションの状態一覧。

\\{zellij-send-dashboard-mode-map}"
  (setq tabulated-list-format
        [("" 2 nil)
         ("状態" 11 nil)
         ("セッション" 16 t)
         ("経過" 6 nil)
         ("無変化" 7 nil)
         ("状況" 0 nil)])
  (setq tabulated-list-padding 1)
  (setq header-line-format
        " RET:移動 o:別窓 e:返信 1/2/3:選択 a:取得 l:ログ c:圧縮 r:遠隔 Q:終了 k:削除 g:更新")
  (tabulated-list-init-header)
  (add-hook 'kill-buffer-hook #'zellij-send-dashboard--stop-timer nil t))

(defun zellij-send-dashboard--connected-sessions ()
  "すでに黒板バッファを持っているセッション名のリストを返す。"
  (mapcar (lambda (buf) (buffer-local-value 'zellij-send--session buf))
          (zellij-send-dashboard--session-buffers)))

(defun zellij-send-dashboard-connect-all ()
  "起動中の zellij セッションのうち、未接続のものに接続する。
cwd と pane-id は zellij から取得するのでユーザーには何も尋ねない。"
  (interactive)
  (zellij-send--list-sessions-async
   (lambda (sessions)
     (if (eq sessions :timeout)
         (message "zellij の応答がタイムアウトしました（5秒）")
       (let ((new (seq-difference sessions
                                  (zellij-send-dashboard--connected-sessions))))
         (when new
           (message "セッションに接続中: %s" (string-join new ", "))
           (dolist (session new)
             (zellij-send-attach-session-async
              session
              (lambda (_buf)
                ;; 接続のたびに一覧へ反映する
                (let ((db (get-buffer zellij-send-dashboard-buffer-name)))
                  (when (buffer-live-p db)
                    (with-current-buffer db
                      (zellij-send-dashboard-refresh)))))))))))))

;;;###autoload
(defun zellij-send-dashboard ()
  "zellij-send セッションのダッシュボードを開く。
`zellij-send-dashboard-auto-connect' が non-nil なら、起動中の zellij
セッションのうちまだバッファの無いものに自動接続する。"
  (interactive)
  (let ((buf (get-buffer-create zellij-send-dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'zellij-send-dashboard-mode)
        (zellij-send-dashboard-mode))
      (zellij-send-dashboard-refresh))
    (pop-to-buffer buf zellij-send-dashboard-display-action)
    ;; ウィンドウができてから高さを合わせる（refresh 時点では未表示のことがある）
    (with-current-buffer buf
      (zellij-send-dashboard--fit-window))
    (zellij-send-dashboard--start-timer)
    (when zellij-send-dashboard-auto-connect
      (zellij-send-dashboard-connect-all))))

(provide 'zellij-send-dashboard)

;;; zellij-send-dashboard.el ends here
