;;; zellij-send-ui.el --- Blackboard buffers for zellij-send -*- lexical-binding: t -*-

;; Copyright (C) 2026 桂市兵衛
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: 桂市兵衛
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4"))
;; URL: https://github.com/ichibeikatura/zellij-send.el

;;; Commentary:

;; 黒板バッファ: メジャーモード、受信した画面の反映と桁揃え、送信履歴、
;; 返信バッファ、Transient メニュー、ダッシュボード向けの公開 API。

;;; Code:

(require 'transient)
(require 'zellij-send-claude)

(declare-function markdown-mode "markdown-mode")

;;; 設定と黒板ごとの状態

(defcustom zellij-send-grid-align t
  "非 nil なら黒板バッファの桁を zellij の画面に揃える。

zellij は罫線 `─' や矢印 `←' などの曖昧幅の文字を 1 桁で数えるが、
日本語環境の Emacs は 2 桁で数え、GUI では全角の字形で描く
（2026-09-15 実測: `─' が Hiragino Sans の 14px、ASCII は 7px）。
有効にすると、このバッファの中だけ次の 3 つを切り替える:

- `char-width-table' を Unicode 本来の幅に戻す
- GUI で 1 桁に収まらない記号を、`zellij-send-grid-symbol-families' の
  字形を縮めたものに差し替える
折り返すかどうかは別の設定（`zellij-send-wrap-screen'）で決める。"
  :type 'boolean
  :group 'zellij-send)

(defcustom zellij-send-wrap-screen t
  "非 nil なら、黒板がペインの画面を映している間も窓の幅で折り返す。
新しい黒板を開いたときの既定値で、黒板ごとに `zellij-send-toggle-wrap'
（メニュー `w'）で切り替えられる。切り替えは受信しても戻らない。

折り返すと、ペインの幅（320 桁）いっぱいに引かれた罫線や窓より広い表が
何行にも折れる。表を見るときだけ切る、という使い方を想定している。
下書きと transcript はこの設定に関わらず折り返す。"
  :type 'boolean
  :group 'zellij-send)

(defcustom zellij-send-max-blank-lines 2
  "黒板に映す画面で、続けて残す空行の数の上限。nil なら詰めない。
Claude Code は入力欄を画面の最下段に描くので、会話が短いうちは本文と
入力欄の間が空行で埋まる。`zellij-send-session-size' で 500 行に広げた
セッションでは、起動直後の黒板が約 485 行の空行になった（2026-10-03 実測）。
これより長い空行の連なりは、この数まで詰める。
詰めるのは黒板に映すときだけで（`zellij-send--screen-for-display'）、
画面の解析には効かない。"
  :type '(choice (const :tag "詰めない" nil) natnum)
  :group 'zellij-send)

(defcustom zellij-send-grid-symbol-families
  '("Menlo" "DejaVu Sans Mono" "STIX Two Math" "Apple Symbols" "Symbola")
  "黒板バッファで記号を 1 桁の幅に収めるために使う字体（先頭から試す）。
既定フォントで 1 桁の幅にならない記号だけ、この字体の字形を縮めて描く。
入っていない字体は飛ばす。実測では Menlo で罫線・矢印の大半が、
STIX Two Math で `⏺' `⎿' が、Apple Symbols で残りの一部が収まった。"
  :type '(repeat string)
  :group 'zellij-send)

(defcustom zellij-send-history-max 50
  "セッションごとに覚えておく送信履歴の数。"
  :type 'integer
  :group 'zellij-send)

;;; スクリーンダンプ

(defun zellij-send--screen-for-display (screen)
  "正規形の SCREEN（`zellij-send--normalize-screen'）を、黒板に映す形にして返す。
行頭の `─' の連なりを削り、長い空行の連なりを `zellij-send-max-blank-lines'
まで詰める。呼ぶのは `zellij-send--update-buffer' だけ。

2026-10-19 までは、この 2 つも受信時に行っていた（`zellij-send--process-dump'）。
その結果をパーサが読んでいたので、罫線の残骸を相手にする処理
（`zellij-send--slash-border-p'）が要り、空行を詰める設定で解析の結果が
変わりえた。表示の整形を解析から切り離すために分けた。"
  (let ((text (zellij-send--trim-end
               (replace-regexp-in-string "^─+" "" screen) '(?\n))))
    ;; 本文と最下段の入力欄の間に挟まった空行を詰める。照合は改行の位置から
    ;; だけ始まり、連なりを 1 回読むだけなので線形時間
    (if (natnump zellij-send-max-blank-lines)
        (replace-regexp-in-string
         (format "\n\\{%d,\\}" (+ zellij-send-max-blank-lines 2))
         (make-string (1+ zellij-send-max-blank-lines) ?\n)
         text t t)
      text)))

;;; transcript（Claude Code の会話履歴）

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
      ;; 画面ではなく文章なので折り返す
      (zellij-send--grid-apply nil)
      (set-buffer-modified-p nil)
      (zellij-send--pending-drop)
      ;; 自動更新に上書きされないよう、クリアと同じ扱いにする
      (setq zellij-send--user-cleared t)
      (zellij-send--clear-prompt-highlight)
      (goto-char (point-max))
      (let ((win (get-buffer-window (current-buffer) t)))
        (when (window-live-p win) (set-window-point win (point-max))))
      (message "会話履歴を表示しました（%s）。生画面に戻すには C-c C-a → g"
               (file-name-nondirectory file)))))

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

(defun zellij-send-forget-session (session)
  "zellij から消えた SESSION の送信履歴を捨てる。
セッション名は空いている最小の連番を使い回す（`zellij-send--numbered-session-name'）
ので、残しておくと同じ名前で作り直したセッションが前の履歴を引き継ぐ。
スラッシュコマンドの一覧のキャッシュはディレクトリ単位でセッションの生死とは
関係ないので、ここでは消さない。"
  (remhash session zellij-send--history-table))

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
自動更新に上書きされないよう、変更済みのままにしておく。"
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
    ;; 辿っていないのに新しい側へ進むと、退避していない下書きを
    ;; 空文字で「復帰」して消してしまう
    (when (and (null zellij-send--history-index) (< delta 0))
      (user-error "履歴を辿っていません"))
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

;;; バッファ更新（共通処理）

;; 黒板の桁揃え（`zellij-send-grid-align'）。320 桁の画面をそのまま映すので、
;; 罫線が 2 桁に伸びたり窓の幅で折り返したりすると形が崩れる。
;; どれもバッファローカルに切り替え、他のバッファの日本語表示には触らない。

(defconst zellij-send--grid-symbol-ranges
  '((#x2010 . #x205E) (#x2190 . #x21FF) (#x2300 . #x23FF)
    (#x2500 . #x25FF) (#x2600 . #x26FF) (#x2700 . #x27BF))
  "GUI で字形の幅を確かめる文字の範囲。
一般句読点・矢印・その他の技術用記号・罫線とブロックと幾何学図形・
その他の記号・装飾記号。TUI が描く記号（`─' `❯' `⏺' `⎿' `✔' `☐' `※'）は
ここに入る。

範囲は約 1000 文字あるが、**先に全部は測らない**。画面に出てきた文字だけを
その場で測る（`zellij-send--grid-fit-symbols'）。全部測ると初回に
0.64 秒かかり（字体の読み込み。2026-09-15 実測）、subscribe の
プロセスフィルタの中で Emacs が固まる。")

(defconst zellij-send--grid-heights '(1.0 0.95 0.9 0.875 0.85 0.8 0.75 0.7 0.65)
  "記号の字形を 1 桁に収めるために試す高さの倍率（大きい順）。")

(defvar zellij-send--grid-tables nil
  "記号を差し替える display-table の控え。
要素は (KEY DISPLAY-TABLE CHECKED)。KEY は (既定フォント名 . 1 桁の px)、
CHECKED は測り終えた文字のハッシュ表。中身は既定フォントだけで決まるので、
黒板バッファ同士で同じ display-table を共有し、見つけた記号を足していく。")

(defun zellij-send--root-char-width-table ()
  "言語環境が積み重ねる前の `char-width-table' を返す。
日本語環境は「曖昧幅を 2 にする表」と「JIS X 0208 を 2 にする表」を
親子にして上に載せる（`use-cjk-char-width-table'）。一番下の親が
Unicode 本来の幅で、zellij の数え方と一致する。"
  (let ((table char-width-table))
    (while (char-table-parent table)
      (setq table (char-table-parent table)))
    table))

(defun zellij-send--grid-pick-face (char cell families measure)
  "CHAR を CELL px で描ける (FAMILY . HEIGHT) を返す。見つからなければ nil。
FAMILIES を順に、`zellij-send--grid-heights' の大きい倍率から試す。
MEASURE は (CHAR FAMILY HEIGHT) を受けて px を返す関数で、その字体に
字形が無ければ nil を返す（その字体はそこで打ち切る）。"
  (cl-loop for family in families
           thereis (cl-loop for height in zellij-send--grid-heights
                            for px = (funcall measure char family height)
                            while px
                            when (= px cell) return (cons family height))))

(defun zellij-send--grid-face (family height)
  "FAMILY を HEIGHT 倍で描くフェイスを返す（無ければ作る）。
display-table の字形にはフェイスの名前しか付けられないので、組み合わせごとに作る。
高さは倍率なので、字形は元の文字のフェイス（太字など）に重ねて効く。"
  (let ((face (intern (format "zellij-send--grid-%s-%s" family height))))
    (unless (facep face)
      (make-face face)
      (set-face-attribute face nil :family family :height height))
    face))

(defun zellij-send--grid-symbols (content)
  "CONTENT に現れる、幅を確かめる対象の記号を重複なしで返す。
対象は `zellij-send--grid-symbol-ranges' の文字。"
  (let ((re (rx-to-string `(any ,@zellij-send--grid-symbol-ranges) t))
        (start 0)
        chars)
    (while (string-match re content start)
      (cl-pushnew (aref content (match-beginning 0)) chars)
      (setq start (match-end 0)))
    (nreverse chars)))

(defun zellij-send--grid-fit-symbols (content)
  "CONTENT の記号のうち、GUI で 1 桁に収まらないものを差し替える。
カレントバッファの既定フォントで測り、`buffer-display-table' に設定する。
字形の幅を測れない端末では何もしない。

`char-width-table' を変えても GUI の描画幅は変わらない（字形の幅で決まる）
ので、この差し替えが要る。フォントセットはバッファごとに持てず、
`face-remap' の `:fontset' も効かなかった（実測）ため display-table を使う。
一度測った文字は覚えておき、測り直さない。"
  (when (display-graphic-p)
    (let* ((cell (default-font-width))
           (key (cons (face-font 'default) cell))
           (entry (or (assoc key zellij-send--grid-tables)
                      (car (push (list key (make-display-table)
                                       (make-hash-table))
                                 zellij-send--grid-tables))))
           (table (nth 1 entry))
           (checked (nth 2 entry))
           (chars (seq-remove (lambda (c) (gethash c checked))
                              (zellij-send--grid-symbols content))))
      (when chars
        (let* ((root (zellij-send--root-char-width-table))
               (buf (current-buffer))
               (fonts (delq nil (mapcar
                                 (lambda (family)
                                   (let ((font (find-font (font-spec :family family))))
                                     (and font (cons family font))))
                                 zellij-send-grid-symbol-families)))
               (measure
                (lambda (char family height)
                  (when (font-has-char-p (cdr (assoc family fonts)) char)
                    (string-pixel-width
                     (propertize (string char)
                                 'face (list :family family :height height))
                     buf)))))
          (dolist (char chars)
            (puthash char t checked)
            (when (and (eql (aref root char) 1)
                       (/= (string-pixel-width (string char) buf) cell))
              (pcase (zellij-send--grid-pick-face
                      char cell (mapcar #'car fonts) measure)
                (`(,family . ,height)
                 (aset table char
                       (vector (make-glyph-code
                                char (zellij-send--grid-face family height))))))))))
      (setq buffer-display-table table))))

(defun zellij-send--grid-apply (screen &optional content)
  "黒板の折り返しと記号の差し替えを、いまの中身に合わせて切り替える。
SCREEN が非 nil ならペインの画面（CONTENT）を映しているので、
`zellij-send--wrap' が nil のときだけ折り返しを切り、CONTENT の記号を
1 桁に収める。nil なら下書きや transcript の文章なので必ず折り返す。"
  (setq truncate-lines (and screen (not zellij-send--wrap)))
  (when (and zellij-send-grid-align screen content)
    (zellij-send--grid-fit-symbols content)))

(defun zellij-send--grid-editing ()
  "書き始めたら折り返しに戻す（`first-change-hook'）。
黒板は入力欄も兼ねるので、長い下書きが右に隠れないようにする。
`--update-buffer' は `with-silent-modifications' で書くのでここを通らない。"
  (zellij-send--grid-apply nil))

(defun zellij-send-toggle-wrap ()
  "この黒板で、画面を折り返すかどうかを切り替える。
既定は `zellij-send-wrap-screen'。切り替えは受信しても戻らない。
表を見たいときに折り返しを切り、読み終えたら戻す、という使い方を想定する。
押した時点の表示にもすぐ効かせる（下書きの途中でも切れる）。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  (setq-local zellij-send--wrap (not zellij-send--wrap))
  (setq truncate-lines (not zellij-send--wrap))
  (when zellij-send--wrap
    ;; 横にずらしたまま折り返すと左端が隠れる（`toggle-truncate-lines' と同じ）
    (dolist (win (get-buffer-window-list nil nil t))
      (set-window-hscroll win 0)))
  (message "黒板の折り返し: %s" (if zellij-send--wrap "する" "しない")))

;; 選択中の書き換えは保留する。`erase-buffer' はマーク（marker）を point-min に
;; 潰すので、C-SPC で置いたマークが受信のたびに先頭へ飛び、選択範囲が壊れる
;; （`emacs -Q' の実機再現で確認）。保留するのは最新の 1 つだけで、選択が
;; 解けたら反映する。解ける合図は 3 つ拾う:
;; - `deactivate-mark-hook': C-g やコマンド終了時の解除。コマンドループが
;;   解除するのは `post-command-hook' より後なので、これが無いと次の
;;   コマンドまで反映が遅れる
;; - `post-command-hook': `deactivate-mark' を通らずに `mark-active' が落ちた場合
;; - `window-selection-change-functions': 選択を残したまま別ウィンドウへ移った場合

(defun zellij-send--defer-update-p ()
  "いま黒板を書き換えると選択を壊すなら non-nil。
region が有効で、しかもこのバッファが選択ウィンドウに出ているときだけ保留する。
`mark-active' 単独で見ないのは、`transient-mark-mode' が無効だと一度マークを
置いただけで真のままになり、更新が永久に止まるため。選択ウィンドウに限るのは、
region を残したまま別のウィンドウへ移ったときに表示を固めないため。"
  (and (region-active-p)
       (eq (current-buffer) (window-buffer (selected-window)))))

(defun zellij-send--pending-drop ()
  "保留中の画面内容を捨てる。
送信・クリアなどで黒板の中身が決まったときに呼ぶ。捨てないと、後で選択を
解いた瞬間に古い画面が復活する。"
  (setq zellij-send--pending-content nil))

(defun zellij-send--pending-resume (buf)
  "BUF で保留していた画面内容を、選択が解けていれば反映する。
保留中に編集・クリアされていたら反映せずに捨てる（入力を上書きしない）。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and zellij-send--pending-content
                 (not (zellij-send--defer-update-p)))
        (let ((content zellij-send--pending-content))
          (zellij-send--pending-drop)
          (when (and (not (buffer-modified-p))
                     (not zellij-send--user-cleared))
            (zellij-send--update-buffer content)))))))

(defun zellij-send--pending-schedule (&rest _)
  "選択が解けていれば、保留分の反映を予約する。
`deactivate-mark-hook' はコマンドの途中からも呼ばれ、ウィンドウの変化フックは
再描画の中で走るので、その場では書き換えず `run-at-time' で抜けてから行う。"
  (when (and zellij-send--pending-content
             (not (zellij-send--defer-update-p)))
    (run-at-time 0 nil #'zellij-send--pending-resume (current-buffer))))

(defun zellij-send--update-buffer (content &optional if-changed)
  "黒板をペインの画面 CONTENT で更新し、プロンプト検出・ハイライトを実行する。
CONTENT は画面の正規形（`zellij-send--normalize-screen'）。黒板には
`zellij-send--screen-for-display' を通した形を映す。
カーソル位置・マーク・ウィンドウの表示開始位置は可能な範囲で復元する
（自動更新のたびに読んでいる箇所が先頭へ飛ぶのを防ぐため）。
選択中（`zellij-send--defer-update-p'）は書き換えず、最新の内容だけを
`zellij-send--pending-content' に取っておく。

IF-CHANGED が non-nil なら、黒板に同じ表示形がもう映っていて保留も無いとき
は何もしない（subscribe は画面が変わらなくてもイベントを送ってくる）。
保留があるときは同じ内容でも書き直す（A → 保留 B → A と戻ったときに、
古い B を保留したままにしないため）。

「同じか」は表示形どうしで比べる。正規形と黒板の中身を比べると、罫線や
空行の扱いが違うので必ず食い違う。`--last-content' の前回値と比べる形に
しないのは、送信後に空にした黒板などを、画面が変わるまで空のまま残すため。"
  (let ((text (zellij-send--screen-for-display content)))
    (cond
     ((zellij-send--defer-update-p)
      ;; 画面と同じ内容に戻ったなら、保留するものは無い
      (setq zellij-send--pending-content
            (unless (string= text (buffer-string)) content)))
     ((and if-changed
           (null zellij-send--pending-content)
           (string= text (buffer-string)))
      nil)
     (t
      (zellij-send--update-buffer-1 content text)))))

(defun zellij-send--update-buffer-1 (content text)
  "黒板を表示形 TEXT で書き換える。CONTENT はその元の画面（正規形）。
`zellij-send--update-buffer' の下請け。"
  (zellij-send--pending-drop)
  (let* ((win (get-buffer-window (current-buffer) t))
         ;; 選択されていない窓では、窓の point とバッファの point が別物になる。
         ;; ユーザーが見ているのは窓の方なので、窓があればそちらを基準にする
         (pos (if (window-live-p win) (window-point win) (point)))
         (follow (= pos (point-max)))
         (mark (mark t))
         (wstart (and (window-live-p win) (window-start win))))
    (with-silent-modifications
      (erase-buffer)
      (insert text))
    (zellij-send--grid-apply t text)
    ;; 末尾にいたら末尾を追う（ターミナルや `M-x compile' と同じ）。送信に
    ;; 成功すると黒板を空にするので、送った直後は自動でここに入り、最新の
    ;; 回答が出る下端が見え続ける。上へ動かして読み始めたら追うのをやめる
    (goto-char (if follow (point-max) (min pos (point-max))))
    ;; `erase-buffer' はマークも point-min に潰す。point と同じく位置で戻す
    (when mark
      (set-marker (mark-marker) (min mark (point-max))))
    (when (window-live-p win)
      (set-window-point win (point))
      (cond
       (follow
        ;; 最下段を窓の下端に合わせる。行数（`vertical-motion'）で開始位置を
        ;; 決めてはいけない。日本語や記号の行は既定の行より背が高いので
        ;; ピクセルでは収まらず、再描画が point を窓の中央へ寄せ直す
        ;; （実測: 36 行の窓で最終行が上から 325px、下に 270px の空白）。
        ;; `recenter' はピクセルで数えるが、選択中の窓にしか効かない
        (with-selected-window win
          (recenter -1)))
       (wstart
        (set-window-start win (min wstart (point-max)) t)))))
  (set-buffer-modified-p nil)
  (if (zellij-send--detect-prompt)
      (zellij-send--highlight-prompt)
    (zellij-send--clear-prompt-highlight))
  (zellij-send--askq-maybe-auto content))


;; 受信（下の層）から黒板を書き換えられるようにする（`zellij-send--display-function'）
(setq zellij-send--display-function #'zellij-send--update-buffer)

;;; インタラクティブコマンド

(defun zellij-send-abort ()
  "この黒板のペインで走っている操作を止める。
止められるのは、スラッシュコマンド一覧の取得（先読みを含む）・引数の確認・
AskUserQuestion への回答。入力欄に打ちかけた文字は Ctrl+U で片付ける。
ペインで動いているエージェント自体を止めるのは `zellij-send-interrupt'。
既存のキーの割り当てを変えないため、キーには割り当てていない（コマンド名で呼ぶ）。"
  (interactive)
  (zellij-send--assert-session)
  (unless (zellij-send--op-abort (current-buffer) "中止しました")
    (message "止める操作はありません")))

(defun zellij-send-send ()
  "バッファのテキストを zellij セッションに送信し、バッファをクリアする。"
  (interactive)
  (zellij-send--assert-session)
  (let* ((session zellij-send--session)
         (buf (current-buffer))
         (tick (buffer-chars-modified-tick))
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
           ;; 送信中に編集された下書きは、そのまま残す。
           (when (= tick (buffer-chars-modified-tick))
             (erase-buffer)
             (set-buffer-modified-p nil)
             (zellij-send--pending-drop)
             (setq zellij-send--user-cleared nil)
             (setq zellij-send--history-index nil)
             (setq zellij-send--history-draft nil)))
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
  (let* ((claude (and (not arg) (zellij-send--capable-p 'transcript)))
         (file (and claude (zellij-send--transcript-file default-directory))))
    (cond
     (file (zellij-send--transcript-show file))
     (t
      (when claude
        (message "transcript が見つかりません。スクリーンを取得します"))
      (let ((tick (buffer-chars-modified-tick)))
        (zellij-send--dump-screen-async
         zellij-send--session
         (lambda (content)
           (cond
            ((null content) (message "スクリーン内容の取得に失敗しました"))
            ;; 取得を待つ間に書き始めた下書きは上書きしない
            ((/= tick (buffer-chars-modified-tick))
             (message "取得中にバッファが編集されたので反映しませんでした"))
            (t (zellij-send--update-buffer content)
               (message "スクリーン内容を取得しました"))))
         t))))))

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
  ;; 取り直す画面の方が新しいので、選択中に保留した分は要らない
  (zellij-send--pending-drop)
  (zellij-send--dump-screen-async
   zellij-send--session
   (lambda (content)
     (cond
      ((null content)
       (message "スクリーン内容の取得に失敗しました（自動更新は再開しました）"))
      ;; 取得を待つ間に書き始めた下書きは上書きしない（自動更新と同じ扱い）
      ((buffer-modified-p)
       (message "取得中にバッファが編集されたので反映しませんでした"))
      (t (zellij-send--update-buffer content)
         (goto-char (point-max))
         (message "ペインの画面に戻しました（自動更新を再開）"))))
   arg))

(defun zellij-send-clear-buffer ()
  "バッファの内容をクリアする。"
  (interactive)
  (erase-buffer)
  (set-buffer-modified-p nil)
  (zellij-send--pending-drop)
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
           (zellij-send-forget-session session)
           (message "セッション [%s] を削除しました（%s）" session reason))
       (message "セッション [%s] の削除に失敗しました (exit: %d)" session exit)))))

(defun zellij-send--await-agent-exit (session pane-id main-buf deadline)
  "SESSION のエージェントが終了するのを待ち、確認できたらセッションを削除する。

**エージェントが終了してもセッションは消えない**（実測: /exit で claude が
落ちてもペインは EXITED=true のまま残り、セッションは list-sessions に居続ける）。
そのため「セッションが消えるのを待つ」だけでは必ずタイムアウトする。
PANE-ID が分かっていれば `list-panes --all' の EXITED 列で終了を検出し、
分かっていなければセッションの消滅を見る（ターミナル側で閉じられた場合に効く）。

DEADLINE（`float-time' の値）を過ぎたら `delete-session --force' に切り替える。
`list-sessions' の失敗（`:failed'）を「セッション 0 件」と解釈しないこと。"
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
       (lambda (result)
         (if (and (eq (car result) :ok) (not (member session (cadr result))))
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

(defun zellij-send--log-rotated-file (file)
  "出力ログ FILE を Stop フックが退避した先の名前を返す。
`claude-log.md' なら `claude-log.1.md'。README のフックスクリプトと同じ規則。"
  (concat (file-name-sans-extension file) ".1" (file-name-extension file t)))

(defun zellij-send--log-choose (file previous)
  "出力ログを開く対象を決める。FILE は現在のログ、PREVIOUS は以前のログを望むか。
返り値は (開くファイル . 添えるメッセージ)。開くものが無ければ nil。

Stop フックはログが上限を超えると `zellij-send--log-rotated-file' へ退避して
新しく書き始める。退避した後の現在のログは短いので、以前のログがあることを
メッセージで知らせる。"
  (let* ((rotated (zellij-send--log-rotated-file file))
         (cur-p (file-exists-p file))
         (old-p (file-exists-p rotated)))
    (cond
     ((and previous old-p) (cons rotated "以前のログを開きました"))
     ((and cur-p old-p)
      (cons file (format "以前のログもあります: %s（C-u で開く）"
                         (file-name-nondirectory rotated))))
     (cur-p (cons file nil))
     (old-p (cons rotated "現在のログが無いので、以前のログを開きました")))))

(defun zellij-send-open-log (&optional previous)
  "Claude の出力ログ（markdown）を別ウィンドウで開く。
ログは Claude Code の Stop フックが `zellij-send-log-file' に追記する。
フックはログが上限を超えると `claude-log.1.md' へ退避して新しく始めるので、
PREVIOUS（`\\[universal-argument]'）を付けるとそちらを開く。退避した
ログがあるときは、現在のログを開いたときにもそう知らせる。

**Claude Code 専用**。同じディレクトリで codex を動かしていると
claude のログが開けてしまい、自分の出力だと誤解する（astra の指摘）。"
  (interactive "P")
  (zellij-send--assert-session)
  (unless (zellij-send--capable-p 'output-log)
    (user-error "出力ログは Claude Code の Stop フックが書くものです（いまは %s）"
                (or (zellij-send--buffer-command) "コマンド不明")))
  (let* ((file (expand-file-name zellij-send-log-file default-directory))
         (choice (zellij-send--log-choose file previous)))
    (unless choice
      (user-error "ログファイルがまだありません: %s" file))
    (find-file-other-window (car choice))
    (when (cdr choice)
      (message "%s" (cdr choice)))))

;;; 返信バッファ

(defun zellij-send--reply-main ()
  "返信バッファの元の黒板バッファを返す。kill されていれば `user-error'。
送り先（セッション・pane-id）は返信バッファにコピーせず、使うたびに
元の黒板から読む。コピーすると、元の黒板で pane-id が検出し直された後も
古いペインへ送り続けるため。

元の黒板が無いときは送らない。セッション名だけで送ると focused pane に
届き、attach クライアントが無ければ届かないか、別のペインに入るため。
返信の本文はバッファに残るので、黒板を開き直して送り直せばよい。"
  (let ((main zellij-send--reply-main-buffer))
    (unless (buffer-live-p main)
      (user-error "元の黒板バッファが閉じられているので送れません。M-x zellij-send で開き直してください（本文は残っています）"))
    main))

(defun zellij-send--reply-send ()
  "返信バッファの内容を送信してバッファを閉じ、元のバッファに戻る。
送り先は送信の時点で元の黒板から読む（`zellij-send--reply-main'）。
元の黒板が kill されていたら送らずに `user-error' にする。"
  (interactive)
  (unless zellij-send--session
    (user-error "セッション情報がありません"))
  (let* ((main-buf (zellij-send--reply-main))
         (session (buffer-local-value 'zellij-send--session main-buf))
         (text (string-trim (buffer-string)))
         (reply-buf (current-buffer))
         (tick (buffer-chars-modified-tick))
         (wconf zellij-send--reply-window-config))
    (when (string-empty-p text)
      (user-error "送信するテキストが空です"))
    ;; `zellij-send--send' はカレントバッファの pane-id を使うので、
    ;; 元の黒板をカレントにして呼ぶ。失敗時は返信バッファを残してテキストを失わない
    (with-current-buffer main-buf
      (zellij-send--send
       session text
       (lambda (ok)
         (when ok
           (zellij-send--history-add session text)
           (when (and (buffer-live-p reply-buf)
                      (with-current-buffer reply-buf
                        (= tick (buffer-chars-modified-tick))))
             (kill-buffer reply-buf)
             (if (window-configuration-p wconf)
                 (set-window-configuration wconf)
               (when (buffer-live-p main-buf)
                 (pop-to-buffer main-buf))))
           (message "送信しました → [%s]" session)))))))

(defun zellij-send--reply-interrupt ()
  "返信バッファから、元の黒板のペインに Esc を送る（`zellij-send-interrupt'）。"
  (interactive)
  (with-current-buffer (zellij-send--reply-main)
    (zellij-send-interrupt)))

(defun zellij-send-reply-number ()
  "数字を入力して zellij セッションに送信する。
数字が選択として効くと確かめたエージェント（能力 `number-reply'）だけ。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--assert-capability 'number-reply)
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
    (define-key map (kbd "C-c C-k") #'zellij-send--reply-interrupt)
    (define-key map (kbd "M-p")     #'zellij-send-history-prev)
    (define-key map (kbd "M-n")     #'zellij-send-history-next)
    map)
  "zellij-send 返信バッファのキーマップ。")

(defun zellij-send-reply ()
  "返信用のバッファを開く。C-c C-c で送信してバッファを閉じる。
送らずに閉じた返信は、次に開いたときにそのまま残っている。

返信バッファは送り先の pane-id もコマンドも持たない。送信と中断
（C-c C-k）のたびに元の黒板から読む（`zellij-send--reply-main'）。
元の黒板を kill した後は送れない（本文は残る）。"
  (interactive)
  (zellij-send--assert-session)
  (let* ((session zellij-send--session)
         (main-buf (current-buffer))
         (wconf (current-window-configuration))
         (name (format "*zellij-reply-%s*" session))
         (fresh (not (get-buffer name)))
         (reply-buf (get-buffer-create name)))
    (with-current-buffer reply-buf
      ;; 開き直したときは書きかけの返信を残す。`text-mode' はバッファ
      ;; ローカル変数を消すので、作ったときだけ呼ぶ
      (when fresh
        (text-mode))
      (setq-local zellij-send--session session)
      ;; 以前の版がコピーした値が残っていれば消す（古いペインに送らないため）
      (kill-local-variable 'zellij-send--pane-id)
      (kill-local-variable 'zellij-send--command)
      (setq-local zellij-send--reply-main-buffer main-buf)
      (setq-local zellij-send--reply-window-config wconf)
      (use-local-map zellij-send-reply-mode-map)
      (setq-local header-line-format
                  (format " Reply → [%s]  |  C-c C-c: 送信して閉じる" session)))
    (pop-to-buffer reply-buf)))

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
    ("x" "表示内容をクリア"         zellij-send-clear-buffer)
    ("w" "折り返しを切り替える（表を見るとき）" zellij-send-toggle-wrap)
    ("=" "直近の編集を diff で見る" zellij-send-show-last-diff)]
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

(defun zellij-send--header-command-suffix ()
  "ヘッダ行に足すコマンド名。Claude Code のときは空文字。
claude 以外を動かしているセッションを見分けるためだけの表示なので、
既定の（＝ほとんどの）場合はヘッダを変えない。"
  (if (equal (zellij-send--buffer-command)
             (zellij-send--command-name zellij-send-default-command))
      ""
    (format " [%s]" (or (zellij-send--buffer-command) "?"))))

(defun zellij-send--mode-setup ()
  "zellij-send-mode の共通セットアップ処理。"
  (setq-local header-line-format
              '(:eval (if zellij-send-keys-mode
                          (format " Session: %s%s  |  ⌨ キー透過中: ↑↓ 選択 / RET 決定 / SPC トグル / C-c C-t 解除"
                                  (or zellij-send--session "?")
                                  (zellij-send--header-command-suffix))
                        (format " Session: %s%s  |  C-c C-c: 送信  C-c C-a: メニュー  C-c C-t: キー透過"
                                (or zellij-send--session "?")
                                (zellij-send--header-command-suffix)))))
  ;; subscribe は pane-id が決まってから張る（`--get-or-create-buffer' 参照）。
  ;; ここで確実に止めておかないと、常駐プロセスがバッファより長生きする
  ;; ——セッションが消えても subscribe 自身は終了しないため、これが唯一の
  ;; 確実な後始末になる。
  (add-hook 'kill-buffer-hook #'zellij-send--subscribe-stop nil t)
  ;; 桁数の数え方を zellij に合わせる（`zellij-send-grid-align'）
  (when zellij-send-grid-align
    (setq-local char-width-table (zellij-send--root-char-width-table)))
  (setq-local zellij-send--wrap zellij-send-wrap-screen)
  (add-hook 'first-change-hook #'zellij-send--grid-editing nil t)
  ;; 選択中に保留した画面を、選択が解けたら反映する（`--update-buffer' の前の注記）
  (add-hook 'deactivate-mark-hook #'zellij-send--pending-schedule nil t)
  (add-hook 'post-command-hook #'zellij-send--pending-schedule nil t)
  (add-hook 'window-selection-change-functions
            #'zellij-send--pending-schedule nil t))

(defvar zellij-send--markdown-late-warned nil
  "markdown-mode が後から読み込まれた旨をもう知らせたなら non-nil。")

(defun zellij-send--markdown-fallback-check ()
  "`text-mode' で定義した黒板に、markdown-mode が後から使えるようになったことを示す。
`zellij-send-mode' の親はこのファイルを読み込んだ時点で決まる。elpaca などで
非同期に入れていると、markdown-mode が入っているのに `text-mode' 派生になることが
あり、再起動すると直るので原因が分からない。モードラインの名前に印を付け、
最初の 1 回だけ理由を知らせる。"
  (when (and (not (derived-mode-p 'markdown-mode))
             (fboundp 'markdown-mode))
    (setq mode-name "ZellijSend[text]")
    (unless zellij-send--markdown-late-warned
      (setq zellij-send--markdown-late-warned t)
      (message "zellij-send は markdown-mode より先に読み込まれたため text-mode で動いています（Emacs を再起動するか、markdown-mode を先に読み込んでください）"))))

(if (require 'markdown-mode nil t)
    (define-derived-mode zellij-send-mode markdown-mode "ZellijSend"
      "zellij セッションにテキストを送るためのモード。
\\{zellij-send-mode-map}"
      (zellij-send--mode-setup))
  (define-derived-mode zellij-send-mode text-mode "ZellijSend"
    "zellij セッションにテキストを送るためのモード。
markdown-mode を読めなかったときの代わり。後から読めるようになったら
`zellij-send--markdown-fallback-check' が印を出す。
\\{zellij-send-mode-map}"
    (zellij-send--mode-setup)
    (zellij-send--markdown-fallback-check)))

;;; セッションの状態と操作（公開 API）

(define-obsolete-variable-alias 'zellij-send-dashboard-active-window
  'zellij-send-active-window "0.1.0")

(defcustom zellij-send-active-window 6.0
  "画面が変化してから何秒間を「処理中」とみなすか。
Claude Code は本文を流している間スピナー行を出さないので、
スピナーだけでは応答中を検出できない。画面が動いていること自体を
処理中の証拠として使う。0 にするとスピナー行だけで判定する。

変化時刻は `zellij-send--last-change-time'（subscribe が記録）を使う。
**ユーザーが編集中でバッファ更新を抑止している間も記録される**ので、
バッファ内容の変化だけを見ていた頃のような取りこぼしは起きない。"
  :type 'number
  :group 'zellij-send)

(define-obsolete-variable-alias 'zellij-send-dashboard-use-hooks
  'zellij-send-use-hooks "0.1.0")

(defcustom zellij-send-use-hooks t
  "non-nil なら、Claude Code のフックが知らせた状態を画面解析より優先する。
フック（README の state-zellij-send.sh）が未設定のセッションは状態を
受け取らないので、これまでどおり画面だけで判定する（`zellij-send--hook-state'）。"
  :type 'boolean
  :group 'zellij-send)

(define-obsolete-variable-alias 'zellij-send-dashboard-hook-stale
  'zellij-send-hook-stale "0.1.0")

(defcustom zellij-send-hook-stale 30.0
  "フックの「作業中」を、画面が何秒動かなければ信用しなくなるか。
ユーザーが Esc で中断したときは Stop フックが来ない（hooks リファレンスに明記）
ので、作業中のまま残ることがある。作業中の Claude Code はスピナーの秒数を
毎秒描き直すので、画面がこれだけ止まっていれば作業は終わっている。"
  :type 'number
  :group 'zellij-send)

(defconst zellij-send--hook-settle 3.0
  "フックの「選択待ち」の後、ダイアログを描き終えるまでに見込む秒数。")

(defun zellij-send--screen-prompt-p (screen)
  "SCREEN に選択肢プロンプトがあれば non-nil。カレントの黒板で呼ぶ。

選択待ちの判定はこの 1 本にまとめる。Claude Code の AskUserQuestion として
読める画面（`zellij-send--askq-parse'）ではそれを正とし、読めない画面でだけ
記号の正規表現（`zellij-send--detect-prompt'）に落ちる。2 つを別々の場所で
使うと食い違いうる（構造の方は、ヒント行の無い最終確認画面も読める）。
AskUserQuestion の形は Claude Code のものなので、その能力を持つと推測できる
黒板（`zellij-send--capable-p'）でだけ試す。SCREEN が nil なら nil。
読むのは末尾の `zellij-send--prompt-tail-lines' 行だけ。"
  (and screen
       (let ((tail (zellij-send--screen-tail screen zellij-send--prompt-tail-lines)))
         (or (and (zellij-send--capable-p 'askq) (zellij-send--askq-parse tail) t)
             (zellij-send--detect-prompt tail)))))

(defun zellij-send--hook-status (now changed-at)
  "カレントの黒板のフックが知らせた状態を、状態のシンボルにして返す。
`prompt'・`working'・`idle' のどれか。使えなければ nil（画面で判定する）。
NOW は現在時刻、CHANGED-AT は画面が最後に変化した時刻（nil なら不明）。

「作業中」は、受け取った時刻と画面の最終変化のどちらからも
`zellij-send-hook-stale' 秒以上経っていたら捨てる（中断では
Stop フックが来ないため）。"
  (when zellij-send-use-hooks
    (let ((time (or zellij-send--hook-state-time 0)))
      (pcase zellij-send--hook-state
        ;; 選択待ちは、知らせの後に画面が描き変わったら捨てる（Esc で閉じた
        ;; ダイアログにも Stop は来ない）。質問や許可の画面が描かれる分だけ
        ;; `zellij-send--hook-settle' 秒は待つ。選択肢が画面に
        ;; 見えていれば、捨てても画面解析が選択待ちにする
        ('waiting (and (<= (or changed-at 0)
                           (+ time zellij-send--hook-settle))
                       'prompt))
        ('working (and (< (- now (max time (or changed-at 0)))
                          zellij-send-hook-stale)
                       'working))
        ('idle 'idle)))))

(defun zellij-send--session-status (now)
  "カレントの黒板の状態を `prompt'・`working'・`idle' で返す。NOW は現在時刻。
フックが状態を知らせていればそれを優先する（`zellij-send--hook-status'）。
無ければ受け取った画面（`zellij-send--last-screen'）から毎回判定する:
- 処理中: スピナー行がある、または画面が
  `zellij-send-active-window' 秒以内に変化した
- 選択待ち: 選択肢プロンプトがある（`zellij-send--screen-prompt-p'。
  フックが選択待ちと知らせた場合も）。処理中より優先する"
  (let* ((changed-at zellij-send--last-change-time)
         (screen (or (zellij-send--last-screen) ""))
         (hook (zellij-send--hook-status now changed-at))
         (working (if hook
                      ;; フックの知らせは画面より確か（本文を流している間も
                      ;; ターンが終わるまで作業中のまま）
                      (eq hook 'working)
                    (or (zellij-send--spinner-p screen)
                        ;; 変化時刻が無い（まだ 1 件も受けていない）なら
                        ;; 「ずっと前から変化なし」とみなす
                        (and changed-at
                             (> zellij-send-active-window 0)
                             (< (- now changed-at)
                                zellij-send-active-window))))))
    (cond ((or (eq hook 'prompt) (zellij-send--screen-prompt-p screen))
           'prompt)
          (working 'working)
          (t 'idle))))

(defun zellij-send-sessions ()
  "生きている黒板バッファのリストを返す。"
  (cl-remove-if-not
   (lambda (buf)
     (and (buffer-live-p buf)
          (eq (buffer-local-value 'major-mode buf) 'zellij-send-mode)
          (buffer-local-value 'zellij-send--session buf)))
   (buffer-list)))

(defun zellij-send-session-name (buf)
  "黒板 BUF の zellij セッション名を返す。"
  (buffer-local-value 'zellij-send--session buf))

(defun zellij-send-session-screen (buf)
  "黒板 BUF が最後に受け取ったペインの画面を返す。分からなければ nil。
黒板の中身ではない（`zellij-send--last-screen'）。zellij は呼ばない。

返すのは正規形（`zellij-send--normalize-screen'。行末の空白は落としてある）。
まだ 1 件も受けていない黒板では中身で代用するので、そのときだけ整えて返す。
呼び出し側が行末を `string-trim-right' で削らずに済むようにするため
（列の間が大きく空いた画面で 2 乗になる。`zellij-send--trim-end'）。"
  (with-current-buffer buf
    (or zellij-send--last-content
        (let ((screen (zellij-send--last-screen)))
          (and screen (zellij-send--normalize-screen screen))))))

(defun zellij-send-session-state (buf)
  "黒板 BUF の状態を plist で返す。zellij は呼ばない。

  :session     セッション名
  :agent       確定したエージェント名。判っていなければ nil
               （`zellij-send-default-command' で代用しない）
  :status      `prompt'（選択待ち）・`working'（作業中）・`idle'（待機）
               （`zellij-send--session-status'）
  :changed-at  画面が最後に変化した時刻（`float-time'）。まだ無ければ nil
  :editing     未送信の下書きがある（黒板の自動更新は止まっている）
  :cleared     ユーザーがクリアした（同上）"
  (with-current-buffer buf
    (list :session zellij-send--session
          :agent (zellij-send--agent-name)
          :status (zellij-send--session-status (float-time))
          :changed-at zellij-send--last-change-time
          :editing (buffer-modified-p)
          :cleared zellij-send--user-cleared)))

(defun zellij-send-to-session (buf text &optional callback)
  "黒板 BUF のペインに TEXT を送り、Enter を押す（`zellij-send--send'）。
完了したら CALLBACK に成功なら t、失敗なら nil を渡して呼ぶ（省略可）。"
  (with-current-buffer buf
    (zellij-send--send zellij-send--session text callback)))

(defun zellij-send-keys-to-session (buf bytes &optional callback)
  "黒板 BUF のペインに BYTES（数値のリスト）をキー入力として送る。
完了したら CALLBACK に終了コードを渡して呼ぶ（`zellij-send--send-keys'）。"
  (with-current-buffer buf
    (zellij-send--send-keys zellij-send--session bytes callback)))

(defun zellij-send-dump-screen (buf callback)
  "黒板 BUF のペインの画面を取り直して CALLBACK に渡す。
失敗したら nil を渡す。CALLBACK は BUF をカレントにして呼ばれる
（`zellij-send--dump-screen-async'）。"
  (with-current-buffer buf
    (zellij-send--dump-screen-async zellij-send--session callback)))

(defun zellij-send-choice-to-session (buf n)
  "黒板 BUF のペインが選択肢待ちなら、選択肢の番号 N を送る。
数字が選択として効くと確かめたエージェントだけ
（能力 `number-reply'。codex には効かない）。
選択待ちかは黒板の中身ではなく受け取った画面で確かめる
（`zellij-send--screen-prompt-p'）。フックの知らせだけでは送らない——
ダイアログが描かれる前に数字を送ると、ただの入力として届く。"
  (with-current-buffer buf
    (zellij-send--assert-capability 'number-reply)
    (unless (zellij-send--screen-prompt-p (zellij-send--last-screen))
      (user-error "[%s] は選択肢待ちではありません" zellij-send--session))
    (let ((session zellij-send--session))
      (zellij-send--send session (number-to-string n)
                         (lambda (ok)
                           (when ok
                             (message "選択 %d を送信 → [%s]" n session))))
      (zellij-send--clear-prompt-highlight))))

(defalias 'zellij-send-list-sessions #'zellij-send--list-sessions-async
  "zellij のセッション一覧を非同期で取って CALLBACK に渡す。
渡すのは (:ok SESSIONS) か (:failed REASON)（REASON はユーザーに見せる文）。
詳細は `zellij-send--list-sessions-async'。")

(provide 'zellij-send-ui)

;;; zellij-send-ui.el ends here
