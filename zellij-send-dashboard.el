;;; zellij-send-dashboard.el --- Dashboard for zellij-send sessions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (zellij-send "0.1.0"))

;;; Commentary:

;; 複数の zellij-send セッションの状態を一覧するダッシュボード。
;;
;; 本体の内部（名前にハイフンが 2 つ続く変数・関数）には触らず、本体の公開 API
;; （`zellij-send-sessions'・`zellij-send-session-state' など）だけを使う。
;; 作業中・選択待ち・待機の判定は本体が行う（`zellij-send-session-state'）。
;; ここで決めるのは「完了」（見ていない間に作業が終わった）だけで、これは
;; ウィンドウの可視性で決まる表示側の概念なので、このファイルが持つ。
;; このファイルは zellij を呼ばない。セッションの検出（未接続のセッションへの
;; 接続・消えたセッションの黒板の片付け）は本体の監視
;; （`zellij-send-start-session-watch'）が行い、黒板が増減したら
;; `zellij-send-sessions-changed-hook' で知らせてくる。
;;
;;   M-x zellij-send-dashboard
;;
;; 表示される情報:
;;   Flag  ✎ = 未送信の下書きあり（＝黒板の自動更新停止中。状態列は画面に追随する）
;;         ‖ = ユーザーがクリアした（＝黒板の自動更新停止中）
;;   St    選択待ち / 完了 / 作業中 / 待機
;;   経過  その状態になってからの時間
;;   無変化 画面内容が最後に変わってからの時間（詰まり検出用）
;;   状況   画面末尾の意味のある行（スピナー行など）

;;; Code:

(require 'zellij-send)
(require 'tabulated-list)
(require 'cl-lib)
(require 'subr-x)
(require 'color)                        ; 使用状況バーの色を薄める

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

(defcustom zellij-send-dashboard-noise-regexps
  '("\\`[[:space:]]*\\'"
    "\\`[─│╭╮╰╯━┃┏┓┗┛[:space:]]*\\'"
    "\\`[❯›>][[:space:]]*\\'"
    "\\`›[[:space:]]*Ask Codex to do anything[[:space:]]*\\'"
    "shortcuts"
    "bypass permissions"
    "^[[:space:]]*⏵⏵")
  "「状況」列を拾うときに読み飛ばす行の正規表現。
入力ボックスやフッタ行を除外し、スピナー行
（例: `✳ Frobnicating… (12s · esc to interrupt)'）を拾うため。

記号は claude の `❯'、codex の `›'、agy の `>' を外す。ただし
**空のプロンプト行を外すだけでは足りない**——codex の入力欄には
プレースホルダ `› Ask Codex to do anything' が入るので、その行だけを
狭く指定して外す（astra の指摘）。`›' で始まる行を全部捨てると
`› 1. …' の選択肢まで消える。処理中の検出
\(`zellij-send-working-regexp' の既定 `esc to interrupt')は
codex も同じ文言を出すのでそのまま効く（実測: `• Working (2s • esc to interrupt)'）。"
  :type '(repeat regexp)
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-show-usage t
  "non-nil ならダッシュボードに Claude の使用状況（/usage 相当）を表示する。
**Claude Code 専用の情報**なので、見出しにも「Claude」と明記する
（他の CLI の残量だと誤解させないため。astra の指摘）。"
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

(defcustom zellij-send-dashboard-usage-bar-style 'face
  "使用状況バーの描き方。
`face'  — 空白に背景色を付ける。フォントに依存せず崩れない（既定）
`block' — █ などのブロック文字を使う。等幅でも字形が行高を超える
          フォント（M PLUS 等）では崩れる
`ascii' — # と - だけで描く。どの環境でも確実"
  :type '(choice (const :tag "背景色（推奨）" face)
                 (const :tag "ブロック文字" block)
                 (const :tag "ASCII" ascii))
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-usage-timezone nil
  "使用状況のリセット時刻に添えるタイムゾーン表記。
nil なら環境変数 TZ、それも無ければ `%Z'（例: JST）を使う。"
  :type '(choice (const :tag "自動" nil) string)
  :group 'zellij-send-dashboard)

(defcustom zellij-send-dashboard-usage-light-ratio 0.4
  "「Current session」のバーを薄くする度合い。
0 なら「Current week」と同じ濃さ、1 なら背景色と同じ（＝見えない）。
5 時間制限と 1 週間制限は同じ使用率だと同じ色になり見分けが付かないため、
5 時間側だけ背景へ寄せて薄くする。色の系統（緑・黄・赤）は変えない。"
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

;; 状態の判定は黒板の中身ではなく、黒板が最後に受け取った画面を読む
;; （`zellij-send-session-state' / `zellij-send-session-screen'）。黒板は下書き・
;; クリア・transcript 表示の間は画面ではない文章を持っているので、それを読むと
;; 状態が画面に追随しない。どちらも zellij を呼ばない。

(defun zellij-send-dashboard--screen (buf)
  "BUF が最後に受け取ったペインの画面を返す。分からなければ空文字。"
  (or (zellij-send-session-screen buf) ""))

(defun zellij-send-dashboard--update-state (buf info)
  "BUF の状態を記録し、その plist を返す。
INFO は `zellij-send-session-state' が返した plist。作業中・選択待ち・待機は
その `:status' をそのまま使い、ここでは「完了」だけを足す:
- 完了: 作業中でなくなった瞬間に立て、バッファを表示した時点で下ろす

記録する plist は (:tick :changed-at :status :status-at :done)。
:changed-at は「無変化」列のための時刻で、本体が記録した最終変化時刻
（INFO の `:changed-at'）を優先する。取れないときだけバッファの tick の
変化で代用する。"
  (let* ((now (float-time))
         (session (plist-get info :session))
         (st (gethash session zellij-send-dashboard--state))
         (tick (buffer-chars-modified-tick buf))
         ;; 本体（subscribe）が記録した最終変化時刻を優先する。バッファ内容の
         ;; 変化だけを見ると、ユーザーが編集中で更新を抑止している間の変化を
         ;; 取りこぼす。取れないときだけ tick の変化で代用する
         (reported (plist-get info :changed-at))
         (changed (and st (not (equal (plist-get st :tick) tick))))
         ;; 初回は「ずっと前から変化なし」とみなす（接続直後に
         ;; 作業中と誤判定しないため）
         (changed-at (cond (reported reported)
                           (changed now)
                           (st (plist-get st :changed-at))
                           (t (- now zellij-send-active-window 1))))
         (prev-status (plist-get st :status))
         (visible (get-buffer-window buf t))
         (base (plist-get info :status))
         (done (and (not (eq base 'working))
                    (not visible)
                    (or (eq prev-status 'working) (plist-get st :done))))
         (status (if (and done (eq base 'idle)) 'done base))
         (status-at (if (and st (eq status prev-status))
                        (or (plist-get st :status-at) now)
                      now)))
    (puthash session
             (list :tick tick :changed-at changed-at
                   :status status :status-at status-at :done done)
             zellij-send-dashboard--state)
    (gethash session zellij-send-dashboard--state)))

(defun zellij-send-dashboard--flag (info)
  "表示が更新停止中かどうかを表す印を返す。
INFO は `zellij-send-session-state' が返した plist。zellij-send の自動更新は
下書きがあるときとクリアしたときに書き換えを止めるため、その場合は
表示が古い旨を明示する。"
  (cond ((plist-get info :cleared)
         (propertize "‖" 'face 'shadow
                     'help-echo "クリア済み: 自動更新停止中"))
        ((plist-get info :editing)
         (propertize "✎" 'face 'font-lock-string-face
                     'help-echo "未送信の下書きあり: 自動更新停止中"))
        (t " ")))

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

(defun zellij-send-dashboard--line-start (string end)
  "STRING の位置 END より前で最後の改行の次の位置を返す。改行が無ければ 0。"
  (let ((i (1- end)))
    (while (and (>= i 0) (/= (aref string i) ?\n))
      (setq i (1- i)))
    (1+ i)))

(defun zellij-send-dashboard--tail-line (buf)
  "BUF の画面末尾から、意味のありそうな行を 1 行拾う。
読むのは黒板の中身ではなく受け取った画面（`zellij-send-dashboard--screen'）。"
  ;; 画面は末尾の改行を落として入るので、最終行から読む。下から 40 行まで。
  ;; 3 秒ごとにセッションの数だけ走るので、500 行の画面を毎回全部
  ;; `split-string' せず、後ろから 1 行ずつ切り出す。
  ;; 行は `string-trim' で削らない。右側の正規表現は行の途中の空白の連なり
  ;; ごとに後戻りするので、列の間が大きく空いた表の画面で 2 乗になる
  ;; （`zellij-send--trim-end' の docstring）。削るのは左だけで、こちらは
  ;; 先頭に錨があるので線形。行末の空白は `zellij-send-session-screen' が
  ;; 落としてある（正規形）
  (let* ((screen (zellij-send-dashboard--screen buf))
         (end (length screen))
         (count 0)
         (line nil))
    (while (and (null line) (< count 40) (>= end 0))
      (let* ((start (zellij-send-dashboard--line-start screen end))
             (s (string-trim-left (substring screen start end))))
        (unless (zellij-send-dashboard--noise-p s)
          (setq line s))
        (setq end (1- start)
              count (1+ count))))
    (truncate-string-to-width (or line "")
                              zellij-send-dashboard-tail-width nil nil "…")))

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
        (bufs (zellij-send-sessions))
        entries sessions)
    (dolist (buf bufs)
      (let* ((info (zellij-send-session-state buf))
             (session (plist-get info :session))
             (st (zellij-send-dashboard--update-state buf info))
             (status (plist-get st :status)))
        (push session sessions)
        (push (list buf
                    (vector (zellij-send-dashboard--flag info)
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

(defvar zellij-send-dashboard--usage-cache nil
  "最後に読んだ使用状況 JSON。(FILE MTIME DATA) の形。")

(defun zellij-send-dashboard--read-usage ()
  "使用状況 JSON を読み、(DATA . MTIME) を返す。読めなければ nil。
再描画（3 秒ごと）のたびに parse しないよう、mtime が変わったときだけ読み直す。"
  (let ((file zellij-send-dashboard-usage-file))
    (when (and file (file-readable-p file))
      (with-demoted-errors "zellij-send-dashboard: usage 読み込み失敗 %S"
        (let ((mtime (file-attribute-modification-time
                      (file-attributes file)))
              (cache zellij-send-dashboard--usage-cache))
          (unless (and (equal (nth 0 cache) file)
                       (equal (nth 1 cache) mtime))
            (setq zellij-send-dashboard--usage-cache
                  (list file mtime
                        (with-temp-buffer
                          (insert-file-contents file)
                          (goto-char (point-min))
                          (json-parse-buffer :object-type 'alist
                                             :null-object nil
                                             :false-object nil)))))
          (cons (nth 2 zellij-send-dashboard--usage-cache) mtime))))))

(defun zellij-send-dashboard--usage-face (pct)
  "PCT に応じたバーの face を返す。"
  (cond ((>= pct 80) 'zellij-send-dashboard-usage-high-face)
        ((>= pct 50) 'zellij-send-dashboard-usage-mid-face)
        (t           'zellij-send-dashboard-usage-low-face)))

(defun zellij-send-dashboard--blend (color toward ratio)
  "COLOR を TOWARD へ RATIO（0-1）だけ寄せた色を \"#rrggbb\" で返す。
どちらかの色名を解決できなければ COLOR をそのまま返す。"
  (let ((a (color-values color))
        (b (color-values toward)))
    (if (not (and a b))
        color
      (apply #'color-rgb-to-hex
             (append (cl-mapcar (lambda (x y)
                                  (/ (+ (* (- 1.0 ratio) x) (* ratio y))
                                     65535.0))
                                a b)
                     (list 2))))))

(defun zellij-send-dashboard--usage-color (pct &optional light)
  "PCT に対応するバーの色を返す。解決できなければ nil。
LIGHT が非 nil なら背景色へ寄せて薄くする（5 時間制限と 1 週間制限を
見分けるため）。"
  (let ((color (face-foreground (zellij-send-dashboard--usage-face pct) nil t))
        (ratio zellij-send-dashboard-usage-light-ratio))
    ;; tty では `color-values' が端末のパレットに丸めるため、混ぜると色相
    ;; ごと壊れる（実測: 橙 #c07000 も赤 #b00000 も純赤に丸められ、混色の
    ;; 結果が同じになる）。薄めるのはグラフィカルなフレームだけにする。
    (if (and color light (numberp ratio) (> ratio 0) (display-graphic-p))
        (zellij-send-dashboard--blend
         color (or (face-background 'default nil t) "white")
         (min 1.0 ratio))
      color)))

(defun zellij-send-dashboard--bar-block (pct width &optional light)
  "PCT を表すブロック文字のバーを WIDTH 桁で返す。
ブロック文字は East Asian Ambiguous のため環境によっては 1 文字 2 桁に
なる。文字数ではなく桁数で割り当てないとバーが 2 倍の長さになるので、
`string-width' で 1 ブロックあたりの桁数を測ってから計算する。"
  (let* ((cell (max 1 (string-width "█")))
         (blocks (max 1 (/ width cell)))
         (eighths (round (* (/ pct 100.0) blocks 8)))
         (full (/ eighths 8))
         (rest (% eighths 8))
         (bar (concat (make-string full ?█)
                      (aref zellij-send-dashboard--bar-partials rest)))
         (color (zellij-send-dashboard--usage-color pct light)))
    (concat (propertize bar 'face (if color
                                      `(:foreground ,color)
                                    (zellij-send-dashboard--usage-face pct)))
            (make-string (max 0 (- width (string-width bar))) ?\s))))

(defun zellij-send-dashboard--bar-face (pct width &optional light)
  "PCT を表すバーを、空白に背景色を付けて WIDTH 桁で返す。
グリフを使わないのでフォントに左右されない（字形が行の高さを超える
フォントでも崩れない）。"
  (let* ((filled (round (* (/ pct 100.0) width)))
         (color (zellij-send-dashboard--usage-color pct light)))
    (concat (propertize (make-string filled ?\s)
                        'face (if color `(:background ,color) 'region))
            (propertize (make-string (- width filled) ?\s)
                        'face 'fringe))))

(defun zellij-send-dashboard--bar-ascii (pct width &optional light)
  "PCT を表すバーを # と - だけで WIDTH 桁で返す。"
  (let ((filled (round (* (/ pct 100.0) width)))
        (color (zellij-send-dashboard--usage-color pct light)))
    (concat (propertize (make-string filled ?#)
                        'face (if color
                                  `(:foreground ,color)
                                (zellij-send-dashboard--usage-face pct)))
            (propertize (make-string (- width filled) ?-) 'face 'shadow))))

(defun zellij-send-dashboard--bar (pct &optional light)
  "PCT（0-100）を表す幅 `zellij-send-dashboard-usage-bar-width' 桁のバーを返す。
描き方は `zellij-send-dashboard-usage-bar-style' で選ぶ。
LIGHT が非 nil なら色を薄くする（`zellij-send-dashboard-usage-light-ratio'）。"
  (let ((width zellij-send-dashboard-usage-bar-width)
        (pct (min 100 (max 0 (or pct 0)))))
    (pcase zellij-send-dashboard-usage-bar-style
      ('block (zellij-send-dashboard--bar-block pct width light))
      ('ascii (zellij-send-dashboard--bar-ascii pct width light))
      (_      (zellij-send-dashboard--bar-face pct width light)))))

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
「ラベル:バー NN% used Resets ...」の 1 行にまとめる（縦を使わない）。
5 時間制限（KEY が `five_hour'）のバーだけ色を薄くして 1 週間制限と
見分けられるようにする。"
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
              (zellij-send-dashboard--bar pct (eq key 'five_hour))
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
                     "Claude 使用状況: レート制限の情報がありません（Claude サブスク以外、または API 応答前）\n"
                   (format "Claude 使用状況: %s がありません（README の statusLine フック設定を参照）\n"
                           (abbreviate-file-name
                            zellij-send-dashboard-usage-file)))
                 'face 'shadow))
      (insert (propertize
               (format "── Claude 使用状況 ─ %s前の記録 %s\n"
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

(defun zellij-send-dashboard-show-response (&optional arg)
  "カーソル行のセッションの会話履歴を表示する（`zellij-send-show-response'）。
Claude Code なら transcript を、それ以外は画面を取得する。
ARG（\\[universal-argument]）付きなら Claude Code でも画面を取得する。"
  (interactive "P")
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-show-response arg)))

(defun zellij-send-dashboard--send-choice (n)
  "カーソル行のセッションが選択肢待ちなら N を送る。
可否の確かめ（数字が効くエージェントか・画面が選択待ちか）は本体の
`zellij-send-choice-to-session' が行う。"
  (zellij-send-choice-to-session (zellij-send-dashboard--buffer-at-point) n))

(defun zellij-send-dashboard-select-1 ()
  "カーソル行のセッションに選択肢 1 を送る。"
  (interactive) (zellij-send-dashboard--send-choice 1))

(defun zellij-send-dashboard-select-2 ()
  "カーソル行のセッションに選択肢 2 を送る。"
  (interactive) (zellij-send-dashboard--send-choice 2))

(defun zellij-send-dashboard-select-3 ()
  "カーソル行のセッションに選択肢 3 を送る。"
  (interactive) (zellij-send-dashboard--send-choice 3))

(defun zellij-send-dashboard-interrupt ()
  "カーソル行のセッションの処理を中断する（Esc を送る）。
状態は問わない。一覧の状態表示は数秒古いことがあり、「作業中に
見えない」ことを理由に中断を拒むと止められなくなるため。"
  (interactive)
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-interrupt)))

(defun zellij-send-dashboard-compact ()
  "カーソル行のセッションに /compact を送る。"
  (interactive)
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-compact)))

(defun zellij-send-dashboard-kill-session ()
  "カーソル行のセッションを終了する（確認あり）。
黒板バッファの `C-c C-a q'（`zellij-send-quit'）と同じ処理。状態は問わない。
かつては待機中のセッションしか終了させなかったが、一覧の状態表示は
画面の変化から推し量ったもので数秒ずれる。終了させたいときには作業は
もう止まっているので、待機中の判定で拒むと止められないだけだった。"
  (interactive)
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-quit)))

(defun zellij-send-dashboard-open-log (&optional previous)
  "カーソル行のセッションの出力ログを開く。
PREVIOUS（`\\[universal-argument]'）付きなら退避した以前のログを開く。"
  (interactive "P")
  (with-current-buffer (zellij-send-dashboard--buffer-at-point)
    (zellij-send-open-log previous)))


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

(defconst zellij-send-dashboard--keys
  '(("移動")
    ("RET" zellij-send-dashboard-visit              "そのセッションのバッファへ移動")
    ("o"   zellij-send-dashboard-visit-other-window "別ウィンドウに表示（一覧に留まる）")
    ("e"   zellij-send-dashboard-reply              "そのセッションの返信バッファを開く")
    ("l"   zellij-send-dashboard-open-log           "そのセッションの出力ログを開く")
    ("送信")
    ("1/2/3" zellij-send-dashboard-select-1         "選択肢の番号を送る")
    ("i"   zellij-send-dashboard-interrupt          "処理を中断する（Esc を送る）")
    ("c"   zellij-send-dashboard-compact            "/compact を送る")
    ("一覧")
    ("g"   zellij-send-dashboard-refresh            "手動で更新する（revert-buffer）")
    ("G"   zellij-send-dashboard-connect-all        "未接続のセッションに接続し、消えた行を消す")
    ("a"   zellij-send-dashboard-show-response      "会話履歴を表示する（C-u で画面を取得）")
    ("?"   zellij-send-dashboard-help               "このキー一覧を出す")
    ("終了")
    ("Q"   zellij-send-dashboard-kill-session       "セッションを終了する（C-c C-a q と同じ）"))
  "ヘルプ（`zellij-send-dashboard-help'）に出すキー一覧。
要素は (KEY COMMAND DESC)、または見出しだけの (TITLE)。
COMMAND はキーマップとの食い違いを検査するために持つ
（`zellij-send-dashboard-help' が実際の割り当てと突き合わせる）。")

(defvar zellij-send-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'zellij-send-dashboard-visit)
    (define-key map (kbd "o")   #'zellij-send-dashboard-visit-other-window)
    (define-key map (kbd "e")   #'zellij-send-dashboard-reply)
    (define-key map (kbd "a")   #'zellij-send-dashboard-show-response)
    (define-key map (kbd "l")   #'zellij-send-dashboard-open-log)
    (define-key map (kbd "i")   #'zellij-send-dashboard-interrupt)
    (define-key map (kbd "c")   #'zellij-send-dashboard-compact)
    (define-key map (kbd "Q")   #'zellij-send-dashboard-kill-session)
    (define-key map (kbd "1")   #'zellij-send-dashboard-select-1)
    (define-key map (kbd "2")   #'zellij-send-dashboard-select-2)
    (define-key map (kbd "3")   #'zellij-send-dashboard-select-3)
    (define-key map (kbd "g")   #'zellij-send-dashboard-refresh)
    (define-key map (kbd "G")   #'zellij-send-dashboard-connect-all)
    (define-key map (kbd "?")   #'zellij-send-dashboard-help)
    map)
  "zellij-send-dashboard-mode のキーマップ。")

(defun zellij-send-dashboard-help ()
  "ダッシュボードのキー一覧を `*zellij-dashboard-help*' に出す。
`q' で閉じる。実際のキーマップと突き合わせ、食い違いがあれば印を付ける。"
  (interactive)
  (let ((map zellij-send-dashboard-mode-map))
    (with-help-window "*zellij-dashboard-help*"
      (princ "zellij-send ダッシュボードのキー\n")
      (dolist (row zellij-send-dashboard--keys)
        (if (null (cdr row))
            (princ (format "\n%s\n" (car row)))
          (let* ((key (nth 0 row))
                 (cmd (nth 1 row))
                 (desc (nth 2 row))
                 ;; 1/2/3 のようにまとめて書いた行は先頭のキーで引く
                 (probe (car (split-string key "/")))
                 (bound (lookup-key map (kbd probe)))
                 (ok (eq bound cmd)))
            (princ (format "  %-5s %s%s\n" key desc
                           (if ok "" (format "  ← 未割り当て（%S）" bound)))))))
      (princ "\n  C-h m で Emacs 標準の説明も見られます。\n"))))

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
  ;; header-line にキーヒントを置いても `tabulated-list-init-header' が
  ;; 列見出しで上書きしてしまう。キー一覧は ? （--help）で出す。
  (tabulated-list-init-header)
  ;; g・M-x revert-buffer・マウスのどれでも同じ更新にする。
  ;; `tabulated-list-revert' は `tabulated-list-entries' を作り直さないので、
  ;; 使用状況の再取得を含む自前の refresh に差し替える。
  (setq-local revert-buffer-function
              (lambda (&rest _) (zellij-send-dashboard-refresh)))
  ;; セッションの監視は止めない。黒板が残っている間は本体が続け、
  ;; すべて消えたら本体が止める（`zellij-send-start-session-watch'）
  (add-hook 'kill-buffer-hook #'zellij-send-dashboard--stop-timer nil t))

(defun zellij-send-dashboard--redisplay ()
  "ダッシュボードが生きていれば再描画する。
本体の監視が黒板を増やした・消したときに呼ばれる
（`zellij-send-sessions-changed-hook'）。"
  (let ((db (get-buffer zellij-send-dashboard-buffer-name)))
    (when (buffer-live-p db)
      (with-current-buffer db
        (zellij-send-dashboard-refresh)))))

(add-hook 'zellij-send-sessions-changed-hook #'zellij-send-dashboard--redisplay)

(defun zellij-send-dashboard-connect-all ()
  "起動中の zellij セッションのうち、未接続のものに接続する。
zellij から消えたセッションのバッファは kill する。
cwd と pane-id は zellij から取得するのでユーザーには何も尋ねない。
`zellij-send-auto-connect' が nil でも接続する（`zellij-send-sync-sessions'）。"
  (interactive)
  (zellij-send-sync-sessions t))

;;;###autoload
(defun zellij-send-dashboard ()
  "zellij-send セッションのダッシュボードを開く。
`zellij-send-auto-connect' が non-nil なら、起動中の zellij
セッションのうちまだバッファの無いものに自動接続する。
開いている間は、黒板が 0 個でも本体のセッションの監視を止めない。"
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
    (zellij-send-start-session-watch buf)
    ;; 監視の初回を待たずに、開いた時点で 1 回突き合わせる
    (zellij-send-sync-sessions)))

(provide 'zellij-send-dashboard)

;;; zellij-send-dashboard.el ends here
