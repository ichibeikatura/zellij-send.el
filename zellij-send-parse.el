;;; zellij-send-parse.el --- Screen and transcript parsers for zellij-send -*- lexical-binding: t -*-

;; Copyright (C) 2026 桂市兵衛
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: 桂市兵衛
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/ichibeikatura/zellij-send.el

;;; Commentary:

;; zellij-send の画面解析の中核。文字列を受けて構造を返す関数だけを置く:
;; ANSI の除去と画面の正規形、AskUserQuestion・スラッシュコマンドの補完メニュー・
;; `list-sessions' / `list-panes' の出力・transcript（JSONL）の解析。
;; zellij も Emacs のバッファの状態も要らない（それらが読む設定はここで定義する）。
;; 依存の一番下。test/zellij-send-parse-test.el の対象の大半はここにある。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)         ; transcript の JSONL を読む
(require 'parse-time)   ; transcript の timestamp（ISO 8601）を解釈する

(defgroup zellij-send nil
  "Send text to zellij sessions."
  :group 'tools)

;;; 設定と黒板ごとの状態

(defcustom zellij-send-transcript-max-block-lines nil
  "transcript の 1 ブロックを表示する最大行数。nil なら省略しない。
ツールの出力（tool_result）はファイル全文を含むことがあるため、
黒板が重いときだけ数値を設定する。"
  :type '(choice (const :tag "省略しない" nil) integer)
  :group 'zellij-send)

(defcustom zellij-send-transcript-max-line-length 2000
  "transcript の 1 行を表示する最大文字数。nil なら省略しない。
画像の base64 や、tool_use の入力を JSON にしたものは改行を含まないため、
1 行が数万文字になる。折り返しで画面が埋まって読めなくなるので、
既定で切り詰める。通常の文章 1 段落は超えない長さにしてある。"
  :type '(choice (const :tag "省略しない" nil) integer)
  :group 'zellij-send)

;;; セッション一覧の取得

(defun zellij-send--parse-sessions (raw)
  "RAW テキスト（list-sessions 出力）から生存セッション名リストを返す。
zellij の出力は 1 行 1 セッションで
「NAME [Created ...] (current)」の形式（ANSI 付き）。
以下は除外する:
- EXITED セッション（送信しても届かないため）
- セッションが 0 件のときの案内文
  （\"No active zellij sessions found.\" — 従来はこれを
  セッション名 \"No\" として拾ってしまっていた）。"
  (delq nil
        (mapcar (lambda (line)
                  (let ((clean (string-trim (zellij-send--strip-ansi line))))
                    (when (and (string-match "\\`\\([^ \t]+\\)[ \t]+\\[Created" clean)
                               (not (string-match-p "EXITED" clean)))
                      (match-string 1 clean))))
                (split-string raw "\n" t))))

;;; スクリーンダンプ

(defun zellij-send--strip-ansi (str)
  "STR から ANSI エスケープシーケンスを除去して返す。

`list-sessions' の出力には今もカラーコードが入るので、この関数は現役。
`dump-screen' の方は zellij が既に平文で返すため保険（`--ansi' 指定時のみ
エスケープが残る）。

除去の順序が重要。文字列終端まで舐める OSC / DCS を先に処理しないと、
最後の 2 文字エスケープ規則が `ESC ]' の 2 文字だけを食って
`0;title' とベル文字が本文に残る。同じ理由で、3 バイト以上になる
nF エスケープ（`ESC ( B' など）も 2 文字規則より前に処理する。"
  (let ((result str))
    ;; OSC: ESC ] ... BEL または ESC ] ... ST(ESC \)
    (setq result (replace-regexp-in-string
                  "\033\\][^\a\033]*\\(?:\a\\|\033\\\\\\)" "" result))
    ;; DCS / SOS / PM / APC: ESC P|X|^|_ ... ST(ESC \)
    (setq result (replace-regexp-in-string
                  "\033[PX^_][^\033]*\033\\\\" "" result))
    ;; CSI: ESC [ ... 英字
    (setq result (replace-regexp-in-string "\033\\[[0-9;?]*[A-Za-z]" "" result))
    ;; nF エスケープ: ESC + 中間バイト(0x20-0x2F)+ + 最終バイト(0x30-0x7E)。
    ;; ESC ( B は 3 バイトなので、下の 2 文字規則だけだと `B' が本文に残る
    (setq result (replace-regexp-in-string "\033[ -/]+[0-~]" "" result))
    ;; その他の 2 文字エスケープ（ESC =、ESC 7、ESC M など）
    (setq result (replace-regexp-in-string "\033." "" result))
    result))

(defun zellij-send--trim-end (string chars)
  "STRING の末尾から、CHARS（文字のリスト）に含まれる文字を取り除いて返す。

**行末の空白を `[ \t]+$' や `string-trim-right' で削ってはいけない**。
行の途中にある空白の連なりの各位置から末尾まで試しては後戻りするので、
連なりの長さの 2 乗かかる。`A' と `B' の間に 318 個の空白がある行を
78 行並べた画面で 1 回 45 ms、受信処理全体で 86 ms だった（2026-10-02、
codex の計測）。表のように列の間が大きく空いた画面で起きる。

ここでは「最後の非空白文字 + 空白だけで末尾まで」を探す。照合を試すのは
非空白文字の位置からだけで、そこから先の空白の連なりは 1 回しか読まない
ので長さに比例する。後ろから `aref' で 1 文字ずつ見るより速い
（500 行の画面で 4.2 ms → 2.6 ms。バイトコンパイル済みで比較）。
一致しないのは、空文字列か CHARS だけでできた文字列のときなので
空文字列を返す。"
  (let ((set (apply #'string chars)))
    (save-match-data
      (if (string-match (concat "[^" set "][" set "]*\\'") string)
          (let ((end (1+ (match-beginning 0))))
            (if (= end (length string)) string (substring string 0 end)))
        ""))))

(defun zellij-send--normalize-screen (raw)
  "dump-screen / subscribe の生テキスト RAW を、ペインの画面の正規形にして返す。
`\\r' を除き、ANSI を除き、各行の行末の空白を落とし、末尾の空行を落とす。
ここまでが「ペインの画面」で、**画面を解析する処理はこの形だけを読む**。
黒板に映すための整形（罫線を削る・空行を詰める）は
`zellij-send--screen-for-display' が別に行う。表示の好み
（`zellij-send-max-blank-lines'）が解析に効かないようにするため。

zellij は `--ansi' を付けない限りエスケープを除去済みの平文を返すので、
`zellij-send--strip-ansi' はここでは保険として通しているだけ。

**行末の空白を必ず削る**。`subscribe' の `viewport' は各行をペイン幅ぶん
スペースで右パディングして返す（`dump-screen' は返さない）ので、320 桁に
広げた背景セッションでは 1 行あたり数百文字の空白が付いてくる（2026-07-29 実測）。
末尾の連続空行もまとめて落とす。ANSI 除去より後に行うこと
（エスケープが残ったままだと行末を正しく判定できない）。"
  (let* ((text (zellij-send--strip-ansi
                (replace-regexp-in-string "\r" "" raw)))
         (text (mapconcat (lambda (line) (zellij-send--trim-end line '(?\s ?\t)))
                          (split-string text "\n") "\n")))
    ;; 画面下端の空行（パディングだけの行）を落とす
    (zellij-send--trim-end text '(?\n))))

;;; transcript（Claude Code の会話履歴）

(defun zellij-send--transcript-ai-title (text)
  "TEXT（JSONL の断片）にある最後の ai-title を返す。無ければ nil。
Claude Code は会話が進むたび ai-title 行を追記するので、
末尾に近いものほど今の題名に近い。壊れた行は読み飛ばす。"
  (with-temp-buffer
    (insert text)
    (goto-char (point-max))
    (let (title)
      (while (and (null title)
                  (re-search-backward "^{.*\"type\":\"ai-title\"" nil t))
        (let ((obj (ignore-errors
                     (json-parse-string
                      (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))
                      :object-type 'alist :array-type 'list
                      :null-object nil :false-object nil))))
          (setq title (and obj (alist-get 'aiTitle obj)))))
      (and (stringp title) (not (string-empty-p title)) title))))

(defun zellij-send--transcript-time (entry)
  "ENTRY の timestamp を `MM-DD HH:MM:SS' に整形する。読めなければ空文字。"
  (let ((ts (alist-get 'timestamp entry)))
    (or (and (stringp ts)
             (ignore-errors
               (format-time-string "%m-%d %H:%M:%S"
                                   (parse-iso8601-time-string ts))))
        "")))

(defun zellij-send--transcript-size (bytes)
  "BYTES を人が読める大きさの文字列にする。"
  (cond ((>= bytes 1048576) (format "%.1f MB" (/ bytes 1048576.0)))
        ((>= bytes 1024)    (format "%.0f KB" (/ bytes 1024.0)))
        (t                  (format "%d B" bytes))))

(defun zellij-send--transcript-block (b)
  "text を持たない会話ブロック B を 1 行の要約にする。
画像は base64 が数 MB の 1 行になり、そのまま出すと黒板が読めなくなるので
必ず要約に置き換える（元データは表示しても意味がない）。"
  (let* ((alist (and (listp b) (listp (car-safe b)) b))
         (type (and alist (alist-get 'type alist))))
    (if (not (equal type "image"))
        (format "%S" b)
      (let* ((src (alist-get 'source alist))
             (data (or (alist-get 'data src) ""))
             (media (or (alist-get 'media_type src)
                        (alist-get 'url src)
                        "image"))
             ;; base64 は元データの約 4/3 の長さ
             (bytes (/ (* 3 (length data)) 4)))
        (if (string-empty-p data)
            (format "[画像 %s]" media)
          (format "[画像 %s %s]" media
                  (zellij-send--transcript-size bytes)))))))

(defun zellij-send--transcript-text (content)
  "tool_result の CONTENT（文字列またはブロックの配列）を文字列にする。"
  (cond
   ((stringp content) content)
   ((listp content)
    (mapconcat (lambda (b)
                 (or (and (listp b) (alist-get 'text b))
                     (zellij-send--transcript-block b)))
               content "\n"))
   (t (format "%S" content))))

(defun zellij-send--transcript-entries (text)
  "transcript の TEXT（JSONL）から会話の要素を順に取り出す。
返り値は plist のリスト（`:role' `:time' `:kind' `:name' `:body' `:sub'）。
会話でない行（mode・ai-title・file-history-snapshot など）は捨てる。
壊れた行は黙って読み飛ばす（書き込み中の末尾行がありうるため）。"
  (let (out)
    (dolist (line (split-string text "\n" t))
      (let ((obj (ignore-errors
                   (json-parse-string line :object-type 'alist
                                      :array-type 'list
                                      :null-object nil
                                      :false-object nil))))
        (when obj
          (let ((type (alist-get 'type obj)))
            (when (member type '("user" "assistant"))
              (let* ((time (zellij-send--transcript-time obj))
                     (sub (and (alist-get 'isSidechain obj) t))
                     (content (alist-get 'content (alist-get 'message obj)))
                     (base (list :role type :time time :sub sub)))
                (if (stringp content)
                    (push (append base (list :kind "text" :body content)) out)
                  (dolist (b content)
                    (let ((kind (alist-get 'type b)))
                      (push
                       (append
                        base
                        (cond
                         ((equal kind "text")
                          (list :kind "text" :body (alist-get 'text b)))
                         ((equal kind "thinking")
                          (list :kind "thinking" :body (alist-get 'thinking b)))
                         ((equal kind "tool_use")
                          (list :kind "tool_use"
                                :name (alist-get 'name b)
                                :body (json-encode (alist-get 'input b))))
                         ((equal kind "tool_result")
                          (list :kind "tool_result"
                                :name (and (alist-get 'is_error b) "エラー")
                                :body (zellij-send--transcript-text
                                       (alist-get 'content b))))
                         (t (list :kind (or kind "?")
                                  :body (zellij-send--transcript-block b)))))
                       out))))))))))
    (nreverse out)))

(defun zellij-send--transcript-clip (body)
  "BODY の各行を `zellij-send-transcript-max-line-length' 文字までに切る。
行数ではなく 1 行の長さを見る。base64 や JSON は改行を持たないので、
行数で切っても画面が埋まるのを止められないため。"
  (let ((max zellij-send-transcript-max-line-length))
    (if (not (and max (natnump max) (> max 0)))
        body
      (mapconcat
       (lambda (line)
         (if (<= (length line) max)
             line
           (concat (substring line 0 max)
                   (format "…（この行はあと %d 文字）" (- (length line) max)))))
       (split-string (or body "") "\n")
       "\n"))))

(defun zellij-send--transcript-trim (body)
  "BODY を読める大きさに切り詰める。
長すぎる行を `zellij-send--transcript-clip' で切ってから、
`zellij-send-transcript-max-block-lines' 行までに縮める。
行を先に切るのは、長い 1 行は行数制限では止まらないため。"
  (let ((body (zellij-send--transcript-clip body))
        (max zellij-send-transcript-max-block-lines))
    (if (not (and max (natnump max)))
        body
      (let ((lines (split-string (or body "") "\n")))
        (if (<= (length lines) max)
            body
          (concat (string-join (seq-take lines max) "\n")
                  (format "\n… （残り %d 行）" (- (length lines) max))))))))

(defun zellij-send--transcript-format (entries)
  "ENTRIES を黒板に流す文字列に整形する。
役割が変わるたびに `## ' 見出しを置き、text 以外のブロックには
`### ' の小見出しを付ける。"
  (let (out (prev nil))
    (dolist (e entries)
      (let* ((role (plist-get e :role))
             (kind (plist-get e :kind))
             (name (plist-get e :name))
             ;; tool_result は role が "user" だが、あなたの発言ではないので分ける
             (head (concat (if (equal kind "tool_result") "tool" role)
                           (if (plist-get e :sub) "（サブ）" ""))))
        (unless (equal head prev)
          (setq prev head)
          (push (format "\n## %s  %s" head (plist-get e :time)) out))
        (unless (equal kind "text")
          (push (format "### %s%s" kind (if name (format "  %s" name) "")) out))
        (push (zellij-send--transcript-trim
               (string-trim (or (plist-get e :body) "")))
              out)))
    (string-trim (string-join (nreverse out) "\n"))))

;;;; 直近の編集を diff で見る

;; tool_use の input の形（2026-10-19 に手元の transcript で確認）:
;;   Edit   {file_path, old_string, new_string, replace_all}
;;   Write  {file_path, content}
;; MultiEdit は手元の transcript に現れなかった。{file_path, edits: [{old_string,
;; new_string}…]} の形のときだけ読み、形が違えば黙って飛ばす。
;; diff は外部の `diff' を呼ばずに Emacs Lisp で組む（新しい依存を足さない）。

(defconst zellij-send--edit-tools '("Edit" "Write" "MultiEdit")
  "`zellij-send-show-last-diff' が読むツール名。これ以外は対象外。")

(defun zellij-send--transcript-user-turn-p (obj)
  "transcript の行 OBJ が、あなたの発言（ターンの始まり）なら non-nil。
role が user でも tool_result だけの行は発言ではない。"
  (and (equal (alist-get 'type obj) "user")
       (not (alist-get 'isSidechain obj))
       (let ((content (alist-get 'content (alist-get 'message obj))))
         (or (stringp content)
             (seq-some (lambda (b) (and (listp b)
                                        (equal (alist-get 'type b) "text")))
                       content)))))

(defun zellij-send--transcript-edits (text)
  "transcript の TEXT（JSONL）から直近の編集を古い順に返す。
直近のターン（最後のあなたの発言より後）の編集をすべて返す。そのターンに
編集が無ければ、transcript の中で最後の編集 1 件だけを返す。無ければ nil。
各要素は plist (:name :file :old :new :content)。MultiEdit は
`edits' の 1 件ずつに分けて Edit と同じ形にする。"
  (let (turn last)
    (dolist (line (split-string text "\n" t))
      (let ((obj (ignore-errors
                   (json-parse-string line :object-type 'alist
                                      :array-type 'list
                                      :null-object nil :false-object nil))))
        (cond
         ((null obj) nil)
         ((zellij-send--transcript-user-turn-p obj) (setq turn nil))
         ((equal (alist-get 'type obj) "assistant")
          (let ((content (alist-get 'content (alist-get 'message obj))))
            (dolist (b (and (listp content) content))
              (when (and (listp b) (equal (alist-get 'type b) "tool_use")
                         (member (alist-get 'name b) zellij-send--edit-tools))
                (dolist (e (zellij-send--tool-use-edits
                            (alist-get 'name b) (alist-get 'input b)))
                  (push e turn)
                  (setq last e)))))))))
    (cond (turn (nreverse turn))
          (last (list last)))))

(defun zellij-send--tool-use-edits (name input)
  "ツール NAME の INPUT を編集の plist のリストにする。形が違えば nil。"
  (let ((file (alist-get 'file_path input)))
    (when (stringp file)
      (pcase name
        ("Write"
         (let ((content (alist-get 'content input)))
           (and (stringp content)
                (list (list :name name :file file :content content)))))
        ("Edit"
         (let ((old (alist-get 'old_string input))
               (new (alist-get 'new_string input)))
           (and (stringp old) (stringp new)
                (list (list :name name :file file :old old :new new)))))
        ("MultiEdit"
         (let ((edits (alist-get 'edits input)))
           (and (listp edits)
                (delq nil
                      (mapcar (lambda (e)
                                (let ((old (and (listp e) (alist-get 'old_string e)))
                                      (new (and (listp e) (alist-get 'new_string e))))
                                  (and (stringp old) (stringp new)
                                       (list :name name :file file
                                             :old old :new new))))
                              edits)))))))))

(defun zellij-send--diff-lines (text)
  "TEXT を diff に載せる行のリストにする。
1 行の長さは `zellij-send--transcript-clip' で切る（transcript 表示と同じ方針）。
行数が `zellij-send-transcript-max-block-lines' を超えたら、そこまでの行と
残りの行数を返す: (LINES . 省いた行数)。"
  (let* ((lines (split-string (zellij-send--transcript-clip
                               (string-remove-suffix "\n" (or text "")))
                              "\n"))
         (max zellij-send-transcript-max-block-lines))
    (if (and (natnump max) (> (length lines) max))
        (cons (seq-take lines max) (- (length lines) max))
      (cons lines 0))))

(defun zellij-send--diff-hunk (old new)
  "OLD を NEW に置き換えた差分を、unified diff の 1 ハンクにして返す。
前後の共通の行は文脈行（` '）にし、間を `-' と `+' にする。
行番号は置き換えた断片の中での番号（ファイル全体の行番号は transcript に無い）。
省いた行は `\\ ' 行で知らせる（diff-mode が本文と取り違えない形）。"
  (let* ((o (zellij-send--diff-lines old))
         (n (zellij-send--diff-lines new))
         (ol (car o)) (nl (car n))
         (head 0) (tail 0))
    (while (and (< head (length ol)) (< head (length nl))
                (equal (nth head ol) (nth head nl)))
      (setq head (1+ head)))
    (while (and (< tail (- (length ol) head)) (< tail (- (length nl) head))
                (equal (nth (- (length ol) 1 tail) ol)
                       (nth (- (length nl) 1 tail) nl)))
      (setq tail (1+ tail)))
    (let ((del (seq-subseq ol head (- (length ol) tail)))
          (add (seq-subseq nl head (- (length nl) tail))))
      (concat
       (format "@@ -1,%d +1,%d @@\n" (length ol) (length nl))
       (mapconcat (lambda (l) (concat " " l "\n")) (seq-take ol head) "")
       (mapconcat (lambda (l) (concat "-" l "\n")) del "")
       (mapconcat (lambda (l) (concat "+" l "\n")) add "")
       (mapconcat (lambda (l) (concat " " l "\n")) (last ol tail) "")
       (if (> (cdr o) 0) (format "\\ 元の断片の残り %d 行は省略\n" (cdr o)) "")
       (if (> (cdr n) 0) (format "\\ 新しい断片の残り %d 行は省略\n" (cdr n)) "")))))

;;; セッション情報の取得（cwd・pane-id）

(defun zellij-send--pane-table (raw)
  "`action list-panes --all' の出力 RAW を (HEADER . ROWS) にして返す。
HEADER は列名のリスト、ROWS は各行のフィールドのリスト。

列は 2 個以上の空白区切りだが、TITLE や COMMAND 自体に空白が入るため
位置を決め打ちにせず、呼び出し側はヘッダから列位置を求めること。
フィールド数がヘッダと食い違う行は捨てる（TITLE に 2 連空白が入った等）。"
  (let* ((lines (split-string (or raw "") "\n" t))
         (header (and lines (split-string (string-trim (car lines))
                                          "[ \t]\\{2,\\}" t))))
    (cons header
          (and header
               (seq-filter
                (lambda (fields) (= (length fields) (length header)))
                (mapcar (lambda (line)
                          (split-string (string-trim (zellij-send--strip-ansi line))
                                        "[ \t]\\{2,\\}" t))
                        (cdr lines)))))))

(defun zellij-send--pane-field (raw pane-id column)
  "`action list-panes --all' の出力 RAW から PANE-ID の行の COLUMN 列を返す。
COLUMN はヘッダの列名（\"EXITED\"・\"COMMAND\" など）。取れなければ nil。
表の読み方は `zellij-send--pane-table'。"
  (let* ((table (zellij-send--pane-table raw))
         (header (car table))
         (pane-col (seq-position header "PANE_ID"))
         (col (seq-position header column)))
    (when (and pane-col col)
      (let ((row (seq-find (lambda (fields) (equal (nth pane-col fields) pane-id))
                           (reverse (cdr table)))))
        (and row (nth col row))))))

(defun zellij-send--parse-terminal-panes (raw)
  "`action list-panes --all' の出力 RAW から端末ペインを順に返す。
各要素は (PANE-ID COMMAND EXITED-P)。plugin ペインは除外する。

**TITLE ではなく COMMAND を見る**。`list-panes'（`--all' 無し）の TITLE は
当てにならない——ターミナルから作ったセッションではペインのタイトルが
セッション名になっていることがある（実測: codex のペインのタイトルが
`zellij-send'）。COMMAND 列には `node /opt/homebrew/bin/codex' のように
実際の起動コマンドが入る。TYPE・COMMAND・EXITED は `--all' にしか出ない。

表の読み方は `zellij-send--pane-table'。"
  (let* ((table (zellij-send--pane-table raw))
         (header (car table))
         (id-col (seq-position header "PANE_ID"))
         (type-col (seq-position header "TYPE"))
         (cmd-col (seq-position header "COMMAND"))
         (exited-col (seq-position header "EXITED")))
    (when (and id-col type-col cmd-col)
      (delq nil
            (mapcar
             (lambda (fields)
               (when (equal (nth type-col fields) "terminal")
                 (let ((cmd (nth cmd-col fields)))
                   (list (nth id-col fields)
                         (unless (member cmd '("-" "")) cmd)
                         (and exited-col
                              (string= (nth exited-col fields) "true"))))))
             (cdr table))))))

(defun zellij-send--parse-layout-cwd (raw)
  "`action dump-layout' の出力 RAW からセッションの cwd を返す（無ければ nil）。"
  (when (string-match "^[[:space:]]*cwd[[:space:]]+\"\\([^\"]+\\)\"" raw)
    (match-string 1 raw)))

;;; スラッシュコマンド（Claude Code の /コマンド全部）

(defconst zellij-send--slash-input-regexp "\\`❯[[:space:]]?\\(.*\\)\\'"
  "入力欄の行に一致する正規表現。1=入力欄の中身。")

(defconst zellij-send--slash-entry-regexp
  "\\`[[:space:]]+\\(?:❯[[:space:]]+\\)?\\(/[A-Za-z0-9:_-]+\\)\\(?:[[:space:]]\\{2,\\}\\(.*\\)\\)?\\'"
  "補完メニューの 1 件に一致する正規表現。1=コマンド名 2=説明。
選択中の項目は行頭の空白の後に `❯' が付く（2026-10-19 実測、Claude Code
v2.1.303。`  ❯ /ndl   国立国会図書館…'）。それが無かった頃の形もそのまま読む。")

(defconst zellij-send--slash-arg-entry-regexp
  "\\`[[:space:]]\\{1,6\\}\\([A-Za-z0-9._~][^[:space:]]\\{0,120\\}\\)\\(?:[[:space:]]\\{2,\\}\\(.*\\)\\)?\\'"
  "引数の候補メニューの 1 件に一致する正規表現。1=候補 2=説明。
コマンド一覧と同じ場所に出るが**先頭に `/' が付かない**
（`autoScroll=' / `enable' / `Documents/'。2026-09-06 実測）。
本文の行を拾わないよう、候補は空白を含まない 1 語に限り、
`/' 始まり（＝コマンド一覧）と記号始まり（`⏺' などの本文の飾り）を除く。")

(defconst zellij-send--slash-arg-max-visible 8
  "1 画面から拾う引数候補の上限。
メニューは実測 5 件までなので、これを超えたら本文を読み違えている。")

(defconst zellij-send--slash-hint-regexp
  "\\`\\(/[A-Za-z0-9:_-]+\\)[[:space:]]+\\(?:\\[\\(.*\\)\\]\\|<\\(.*\\)>\\)\\'"
  "入力欄に出る引数ヒントに一致する正規表現。1=コマンド名 2/3=ヒント。
角括弧（`/effort  [low|medium|…]'）と山括弧（`/add-dir  <path>'）の
両方が使われる（実測）。片方だけを見ると `/add-dir' のような
コマンドを「引数なし」と誤判定する。")

(defun zellij-send--slash-border-p (line)
  "LINE が入力枠の罫線なら non-nil。
`─' だけの行と、v2.1.220 の頃の `──── ↯ ─' の形の両方に当たる。
2026-10-19 までは受信時に行頭の ─ を削っていたので、罫線は
\" ↯ ─\" のような短い残骸や空行になって届いていた（その形も読める）。"
  (string-match-p "\\`[[:space:]↯─]*\\'" line))

(defun zellij-send--slash-input-text (screen)
  "SCREEN の入力欄の中身を返す。入力欄が見つからなければ nil。
一番下の ❯ 行を入力欄とみなす。"
  (let* ((lines (split-string screen "\n"))
         (i (zellij-send--askq-last-index lines zellij-send--slash-input-regexp)))
    (when i
      (let ((line (nth i lines)))
        (string-match zellij-send--slash-input-regexp line)
        (string-trim-right (match-string 1 line))))))

(defun zellij-send--sgr-faint (params faint)
  "SGR の引数文字列 PARAMS を当てた後の「薄い字」の状態を返す。
FAINT は当てる前の状態。拡張色（38;5;N / 38;2;R;G;B）の数値は属性と
読まない（`38;5;2' の 2 を薄い字と取り違えないため）。"
  (let ((ps (mapcar (lambda (p) (if (string-empty-p p) 0 (string-to-number p)))
                    (split-string params "[;:]"))))
    (while ps
      (let ((p (pop ps)))
        (cond
         ((memq p '(38 48 58))
          (pcase (pop ps)
            (5 (pop ps))
            (2 (setq ps (nthcdr 3 ps)))))
         ((memq p '(0 22)) (setq faint nil))
         ((= p 2) (setq faint t)))))
    faint))

(defun zellij-send--blank-faint-input (raw)
  "`dump-screen --ansi' の生テキスト RAW の入力欄から、薄い字だけの中身を消して返す。
Claude Code はターンを終えると、次に打ちそうな文を入力欄に薄い字（SGR 2）で
提案する。平文の `dump-screen' では本物の入力と見分けられず、入力欄が空でない
と読んでスラッシュコマンドを打てなかった（2026-10-21 実測、Claude Code
2.1.304・zellij 0.45.1。`❯' の後ろが SGR 2 の提案文で、空の入力欄は `❯' だけ）。
薄くない文字が 1 つでもあれば本物の入力なので、そのまま返す。
TODO(要・手元確認): 打ちかけの本物の入力が薄い字で描かれないこと（未採取）。"
  (let* ((lines (split-string raw "\n"))
         (i (zellij-send--askq-last-index
             (mapcar #'zellij-send--strip-ansi lines)
             zellij-send--slash-input-regexp)))
    (if (null i)
        raw
      (let ((line (nth i lines))
            (pos 0) (faint nil) (after-prompt nil) (dim nil) (real nil))
        ;; 見える文字の区切りごとに、その時点の薄い字の状態で数える
        (cl-flet ((visible (seg)
                    (let ((seg (zellij-send--strip-ansi seg)))
                      (unless after-prompt
                        (let ((k (string-search "❯" seg)))
                          (when k
                            (setq after-prompt t
                                  seg (substring seg (1+ k))))))
                      (when (and after-prompt
                                 (string-match-p "[^[:space:] ]" seg))
                        (if faint (setq dim t) (setq real t))))))
          (while (string-match "\e\\[\\([0-9;:?]*\\)\\([@-~]\\)" line pos)
            ;; `visible' の中の `zellij-send--strip-ansi' が一致を上書きするので先に控える
            (let ((beg (match-beginning 0))
                  (end (match-end 0))
                  (sgr (and (equal (match-string 2 line) "m")
                            (match-string 1 line))))
              (visible (substring line pos beg))
              (when sgr
                (setq faint (zellij-send--sgr-faint sgr faint)))
              (setq pos end)))
          (visible (substring line pos)))
        (if (and dim (not real))
            (string-join (append (seq-take lines i) (list "❯")
                                 (nthcdr (1+ i) lines))
                         "\n")
          raw)))))

(defun zellij-send--slash-idle-p (screen)
  "SCREEN の入力欄が空（入力を受け付けられる状態）なら non-nil。
プレースホルダ（`Try \"...\"'）は空とみなす。ターン後の提案文は平文では
見分けられないので、画面を `--ansi' で取って `zellij-send--blank-faint-input'
で消してから渡す（`zellij-send--slash-wait-idle'）。選択肢プロンプトが出ている間は
矢印キーがそちらに効いてしまうので `zellij-send--askq-parse' で弾く。"
  (let ((text (zellij-send--slash-input-text screen)))
    (and text
         (null (zellij-send--askq-parse screen))
         (or (string-empty-p text)
             (string-prefix-p "Try \"" text)))))

(defun zellij-send--slash-menu-block (screen regexp &optional limit)
  "SCREEN の入力枠のすぐ上のメニューを REGEXP で読み、((値 . 説明) ...) を返す。
LIMIT が non-nil ならその件数を読んだところでやめる。
説明の折り返し行（深いインデントの続き行）は読み飛ばす。"
  (let* ((lines (split-string screen "\n"))
         (i (zellij-send--askq-last-index lines zellij-send--slash-input-regexp))
         (entries nil))
    (when i
      (let ((j (1- i))
            (skipped 0)
            (stop nil))
        ;; 入力枠の上罫線は高々 2 行だけ読み飛ばす。空行をいくらでも跨ぐと
        ;; メニューではない本文まで拾ってしまう
        (while (and (>= j 0) (< skipped 2)
                    (zellij-send--slash-border-p (nth j lines)))
          (setq j (1- j) skipped (1+ skipped)))
        (while (and (>= j 0) (not stop))
          (let ((line (nth j lines)))
            (cond
             ((string-match regexp line)
              (push (cons (match-string 1 line)
                          (let ((desc (match-string 2 line)))
                            (and desc (string-trim desc))))
                    entries)
              (when (and limit (>= (length entries) limit))
                (setq stop t)))
             ;; 説明の折り返し（深いインデントの続き行）
             ((string-match-p "\\`[[:space:]]\\{8,\\}[^[:space:]]" line) nil)
             (t (setq stop t))))
          (setq j (1- j)))))
    entries))

(defun zellij-send--slash-menu-entries (screen)
  "SCREEN の補完メニューから ((\"/name\" . \"説明\") ...) を上から順に返す。"
  (zellij-send--slash-menu-block screen zellij-send--slash-entry-regexp))

(defun zellij-send--slash-arg-entries (screen)
  "SCREEN の引数候補メニューから ((\"値\" . \"説明\") ...) を上から順に返す。
コマンド一覧と同じ場所に出るが、行の形が違う（先頭に `/' が付かない）。"
  (zellij-send--slash-menu-block screen zellij-send--slash-arg-entry-regexp
                                 zellij-send--slash-arg-max-visible))

(defun zellij-send--slash-arg-hint (screen name)
  "SCREEN の入力欄から NAME の引数ヒント（角括弧の中身）を返す。無ければ nil。"
  (let ((text (zellij-send--slash-input-text screen)))
    (when (and text
               (string-match zellij-send--slash-hint-regexp text)
               (equal (match-string 1 text) name))
      (or (match-string 2 text) (match-string 3 text)))))

(defun zellij-send--slash-hint-kind (hint)
  "HINT がパスを求めていれば `directory' か `file'、そうでなければ nil。
`/add-dir  <path>' の類はペインに聞き返すより Emacs 側で補完した方が早い
（ペインの候補は途中まで打たないと出てこない。2026-09-06 実測）。"
  (let ((h (downcase (string-trim (or hint "")))))
    (cond
     ((member h '("path" "dir" "directory" "folder")) 'directory)
     ((member h '("file" "filename" "filepath")) 'file))))

(defun zellij-send--slash-hint-values (hint)
  "HINT から選択肢のリストを返す。選択肢の形でなければ nil。

`low|medium|high' のような素直な形だけではない。claude 本体の
argumentHint を調べると `[codex|gemini] [--dry-run]' や
`[reconnect <server>|enable|disable [<server>|all]]' のように
グループが 2 つあったり入れ子になったりする。**括弧の外の `|' でだけ**切り、
各選択肢から入れ子の括弧（その選択肢の引数）と `<...>'（自由入力）を落として、
1 語で残ったものだけを候補にする。最上位で閉じ括弧が来たら、そこから後ろは
別のグループ（`[codex|gemini] [--dry-run]' の `--dry-run'）なので読まない。
候補に無い値も打てる（require-match しない）ので、落としすぎても困らない。

2026-10-19 実測（Claude Code v2.1.303）: `/effort' のヒントが
`[low|medium|high|xhigh|max|auto|ultracode [on|off]]' になった。`|' で単純に
切っていた頃は `ultracode' が落ち、その引数の `off' が候補に混ざっていた。"
  (when (and hint (string-match-p "|" hint))
    (let ((depth 0) (start 0) (i 0) (n (length hint)) (pieces nil) (stop nil))
      (while (and (< i n) (not stop))
        (let ((c (aref hint i)))
          (cond
           ((memq c '(?\[ ?<)) (setq depth (1+ depth)))
           ((memq c '(?\] ?>))
            (if (> depth 0) (setq depth (1- depth)) (setq stop t)))
           ((and (eq c ?|) (= depth 0))
            (push (substring hint start i) pieces)
            (setq start (1+ i)))))
        (unless stop (setq i (1+ i))))
      (push (substring hint start i) pieces)
      (delete-dups
       (delq nil
             (mapcar
              (lambda (piece)
                ;; 入れ子の括弧から後ろはその選択肢の引数、`<...>' は自由入力
                (let ((s (string-trim
                          (replace-regexp-in-string
                           "<[^>]*>" " "
                           (car (split-string piece "\\["))))))
                  (and (string-match-p
                        "\\`[A-Za-z0-9][A-Za-z0-9._:@/=+-]*\\'" s)
                       s)))
              (nreverse pieces)))))))

(defun zellij-send--slash-arg-open-p (token)
  "TOKEN が書きかけ（`=' `:' `/' で終わる）なら non-nil。
`/config autoScroll=' まで打つと候補が `autoScroll=true' に変わる（実測）。
この状態では空白を足さずに続きを聞き、候補はトークンごと置き換える。"
  (and token (string-match-p "[=:/]\\'" token)))

(defun zellij-send--slash-arg-append (args value &optional replace)
  "引数文字列 ARGS に候補 VALUE を足した文字列を返す。
REPLACE が non-nil なら足さずに末尾のトークンを置き換える。
メニューの候補は**トークン全体**で返る（`autoScroll=' の次の候補は
`autoScroll=true'、`air' まで打つと `airwallex-dev@…'）ので、書きかけの
トークンに続けて選んだ候補は置き換えないと二重になる。
置き換えるかどうかは画面から推測せず、**打った側が覚えておく**
（プラグイン名が偶然そのトークンで始まることがあるため）。"
  (let ((tokens (split-string (or args "") "[[:space:]]+" t)))
    (string-join
     (if (and replace tokens)
         (append (butlast tokens) (list value))
       (append tokens (list value)))
     " ")))

(defun zellij-send--slash-probe-text (name args &optional open)
  "NAME の引数 ARGS の続きを聞くために入力欄へ打つ文字列を返す。
OPEN（末尾のトークンが書きかけ）なら空白を足さずに聞く——その状態では
メニューが打った文字で絞り込まれる。そうでなければ末尾に空白を足す
——空白を打って初めて次の候補やヒントが出る。"
  (let ((args (string-trim (or args ""))))
    (cond
     ((string-empty-p args) (concat name " "))
     ((or open (zellij-send--slash-arg-open-p args)) (concat name " " args))
     (t (concat name " " args " ")))))

;;; インタラクティブコマンド

(defun zellij-send--parse-pane-exited (raw pane-id)
  "`action list-panes --all' の出力 RAW から PANE-ID の EXITED 列を返す。
終了していれば t、動いていれば nil、判定できなければ `:unknown'。
判定できないときに **絶対に t を返さないこと**（t は「セッションを消して
よい」の合図なので、誤検出が最も危険）。列の読み方は
`zellij-send--pane-field' 参照。"
  (let ((exited (zellij-send--pane-field raw pane-id "EXITED")))
    (if exited (string= exited "true") :unknown)))

;;; AskUserQuestion（選択肢プロンプト）への回答

;; Claude Code の AskUserQuestion は次の形で描かれる（2026-07-29 実測、
;; Claude Code v2.1.220 / zellij 0.44.3。詳細は CLAUDE.md 参照）:
;;
;;   ←  ☐ 好きな色  ☒ 好きな果物  ✔ Submit  →   ← 質問タブ（☒ = 回答済み）
;;
;;   好きな果物はどれですか（複数選択可）？      ← 質問文
;;
;;   ❯ 1. [ ] りんご                            ← ❯ = カーソル、[ ] = 複数選択
;;     定番。シャキシャキした食感。              ← 説明（折り返すこともある）
;;     2. [✔] みかん
;;     5. [ ] Type something                    ← 自由入力
;;        Submit
;;   ────────────────────────────
;;     6. Chat about this
;;
;;   Enter to select · Tab/Arrow keys to navigate · Esc to cancel
;;
;; **数字キーが直接効く**のがこの実装の土台。単一選択なら数字 1 つで即回答して
;; 次の質問へ自動で進み、複数選択なら数字がその選択肢のトグルになる（カーソルは
;; 動かない）。したがって QR メニューのようにカーソル移動量を数える必要が無い。
;; 移動量を数えずに済むこと自体が堅牢性で、説明文の折り返しに影響されない。
;;
;; そのほか実測で確定した挙動:
;; - ←/→ が質問タブの移動。Tab は前進のみでラップしない
;; - 複数選択の質問からは → で「Review your answers」へ直行できる
;; - 自由入力（Type something）はカーソルを合わせると入力欄になる。
;;   本文は `paste' で入れる。単一選択ならそのまま Enter で確定、
;;   複数選択なら Enter は不要（→ で Review へ）
;; - 最終確認は `❯ 1. Submit answers / 2. Cancel`。ここも数字で選べる。
;;   **この画面にはヒント行が出ない**ので、ヒント行だけを検出条件にすると
;;   確認画面で止まってしまう（実機の通し確認で踏んだ）
;; - 質問が 1 つだけの単一選択にはタブ行も Review も無く、選んだ時点で確定する
;;
;; **質問を transcript から読むことはできない**（2026-10-19 実測、
;; Claude Code 2.1.303 / zellij 0.45.1）。ペインに質問が出たのは呼び出しから
;; 5.2 秒後だったが、AskUserQuestion の tool_use の行が transcript に書かれたのは
;; 回答した後（212 秒後）で、tool_result の行と同時だった。回答待ちの間は
;; transcript に質問が無いので、ラベルと説明は画面から読むしかない。
;; 構造で取るなら PreToolUse フック（tool_input に questions が入る）が候補。
;; → 実装した（`zellij-send--askq-enrich'）。2026-10-19 実測、同じ版で:
;; 質問がペインに出た 6.35 秒の時点で、state-zellij-send.sh 経由の質問 2 つの
;; 原文と「選択待ち」が既に黒板に届いていた（PreToolUse は描画より先に来る）。
;;
;; 2026-10-19 実測（Claude Code v2.1.303 / zellij 0.45.1）: 単一選択・自由入力に
;; カーソル・複数選択・最終確認の 4 画面とも、上の 2026-07-29 の形のままだった
;; （test/fixtures/askq-*.txt）。複数選択のヒント行から `ctrl+g to edit in Vim'
;; の項が消えていたが、`zellij-send-askq-hint-regexp' は両端しか見ないので影響しない。

(defcustom zellij-send-askq-hint-regexp "^Enter to select · .*Esc to cancel"
  "AskUserQuestion の画面を見分けるための正規表現。
Claude Code が選択肢プロンプトの最下部に必ず出すヒント行に一致する。"
  :type 'regexp
  :group 'zellij-send)

(defcustom zellij-send-askq-other-regexp "\\`Type something\\.?\\'"
  "自由入力（その他）の選択肢ラベルに一致する正規表現。"
  :type 'regexp
  :group 'zellij-send)

(defconst zellij-send--askq-option-regexp
  "^\\(❯\\)?[[:space:]]*\\([0-9]+\\)\\.[[:space:]]+\\(\\[\\(.\\)\\][[:space:]]+\\)?\\(.*?\\)[[:space:]]*$"
  "選択肢の行に一致する正規表現。
1=カーソル 2=番号 3=チェックボックス全体 4=チェック文字 5=ラベル。")

(defconst zellij-send--askq-review-regexp "Ready to submit your answers"
  "最終確認画面を見分けるための正規表現。
確認画面にはヒント行（`zellij-send-askq-hint-regexp'）が出ない（実測）ため、
この行が確認画面を見つける唯一の目印になる。")

(defun zellij-send--askq-last-index (lines regexp)
  "LINES で REGEXP に一致する最後の行番号を返す。無ければ nil。"
  (let ((i (1- (length lines))) found)
    (while (and (>= i 0) (not found))
      (when (string-match-p regexp (nth i lines))
        (setq found i))
      (setq i (1- i)))
    found))

(defun zellij-send--askq-region-start (lines hint)
  "LINES の HINT 行より上で、質問ブロックの開始行番号を返す。
タブ行（☐ / ☒）か「Review your answers」を目印にする。
見つからなければ HINT の 25 行上で打ち切る（画面全体を舐めないため）。"
  (let ((i (1- hint))
        (floor-idx (max 0 (- hint 25)))
        (found nil))
    (while (and (>= i floor-idx) (not found))
      (when (string-match-p "[☐☒]\\|^Review your answers" (nth i lines))
        (setq found i))
      (setq i (1- i)))
    (or found floor-idx)))

(defun zellij-send--askq-separator-p (line)
  "LINE が罫線だけの行なら non-nil。"
  (string-match-p "\\`[[:space:]─━-]*\\'" line))

(defun zellij-send--askq-parse (screen)
  "SCREEN に AskUserQuestion があれば plist を返す。無ければ nil。

返す plist:
  :kind      `question' か `review'
  :question  質問文
  :multi     複数選択なら t
  :options   選択肢のリスト。各要素は
             (:num N :label \"...\" :desc \"...\" :checked BOOL
              :box BOOL :focused BOOL)"
  (when (and screen
             (or (string-match-p zellij-send-askq-hint-regexp screen)
                 (string-match-p zellij-send--askq-review-regexp screen)))
    (let* ((lines (split-string screen "\n"))
           (n (length lines))
           (hint (zellij-send--askq-last-index lines zellij-send-askq-hint-regexp))
           (rev (zellij-send--askq-last-index lines zellij-send--askq-review-regexp))
           ;; 確認画面にはヒント行が無い（実測）。どちらの目印が下にあるかで
           ;; 読む範囲を決める。ヒントだけを頼りにすると確認画面を取り逃がす
           (use-review (and rev (or (null hint) (> rev hint))))
           (region (if use-review
                       (seq-subseq lines rev (min n (+ rev 10)))
                     (seq-subseq lines
                                 (zellij-send--askq-region-start lines hint)
                                 hint)))
           (options nil)
           (question nil)
           (review nil))
      (dolist (line region)
        (cond
         ((string-match-p "Ready to submit your answers" line)
          (setq review t))
         ((string-match zellij-send--askq-option-regexp line)
          (push (list :num (string-to-number (match-string 2 line))
                      :label (match-string 5 line)
                      :desc nil
                      :checked (equal (match-string 4 line) "✔")
                      :box (and (match-string 3 line) t)
                      :focused (and (match-string 1 line) t))
                options))
         ((or (string-empty-p (string-trim line))
              (zellij-send--askq-separator-p line)
              (string-match-p "[☐☒]" line))
          nil)
         (options
          ;; 選択肢の直後の非空行は説明。折り返した 2 行目以降は捨てる
          (unless (plist-get (car options) :desc)
            (setcar options (plist-put (car options) :desc (string-trim line)))))
         (t
          ;; 選択肢より前の非空行が質問文。複数行なら最後の 1 行を採る
          (setq question (string-trim line)))))
      (when options
        (setq options (nreverse options))
        (list :kind (if review 'review 'question)
              :question (or question "質問")
              :multi (and (seq-some (lambda (o) (plist-get o :box)) options) t)
              :options options)))))

(defun zellij-send--askq-signature (q)
  "Q の同一性を判定するための文字列を返す。"
  (format "%s|%s" (plist-get q :question)
          (mapconcat (lambda (o) (format "%s%s%s"
                                         (plist-get o :num)
                                         (plist-get o :label)
                                         (if (plist-get o :checked) "*" "")))
                     (plist-get q :options) ",")))

(defun zellij-send--askq-other-p (opt)
  "OPT が自由入力（その他）の選択肢なら non-nil。"
  (string-match-p zellij-send-askq-other-regexp (plist-get opt :label)))

(defun zellij-send--askq-digits (opt)
  "OPT の番号を打つためのバイト列を返す。"
  (string-to-list (number-to-string (plist-get opt :num))))

(defun zellij-send--askq-candidate (opt)
  "OPT を completing-read の候補文字列にする。"
  (format "%d. %s%s%s"
          (plist-get opt :num)
          (if (plist-get opt :box)
              (if (plist-get opt :checked) "[✔] " "[ ] ")
            "")
          (plist-get opt :label)
          (if (plist-get opt :desc)
              (format "  — %s" (plist-get opt :desc))
            "")))

(defun zellij-send--askq-squash (text)
  "TEXT から空白をすべて取り除く（画面の折り返しと原文を比べるため）。"
  (replace-regexp-in-string "[[:space:]]+" "" (or text "")))

(defun zellij-send--askq-enrich (q questions)
  "画面から読んだ質問 Q のラベルと説明を、フックの QUESTIONS で置き換えて返す。
QUESTIONS は `zellij-send--hook-questions'。合わなければ Q をそのまま返す。

画面からは、折り返した説明の 1 行目しか読めない（`zellij-send--askq-parse'）。
フックの tool_input には質問・選択肢・説明が構造のまま入っているので、
それを正本にする。ただし**画面と照合できたときだけ**使う——同じ質問かは
質問文（画面の最後の行が原文の末尾と一致するか。質問が 1 つならそれ）で、
選択肢の対応は番号順に画面のラベルが原文の頭と一致するかで確かめる。
古い質問や読み違いを持ち込まないため。カーソル・チェック状態・
自由入力などの付け足しの選択肢は、画面のものを使う（原文には無い）。

質問を transcript から読まないのは、回答するまで transcript に書かれない
ため（askq 節の冒頭の 2026-10-19 実測）。"
  (let* ((screen-q (zellij-send--askq-squash (plist-get q :question)))
         (matched (seq-filter
                   (lambda (h)
                     (let ((text (zellij-send--askq-squash (alist-get 'question h))))
                       (and (not (string-empty-p screen-q))
                            (string-suffix-p screen-q text))))
                   questions))
         (h (cond ((= (length matched) 1) (car matched))
                  ((and (null matched) (= (length questions) 1)) (car questions))))
         (hopts (and h (alist-get 'options h)))
         (opts (plist-get q :options)))
    (if (or (null hopts) (eq (plist-get q :kind) 'review)
            (not (seq-every-p
                  (lambda (i)
                    (let ((o (seq-find (lambda (o) (= (plist-get o :num) (1+ i))) opts))
                          (label (zellij-send--askq-squash
                                  (alist-get 'label (nth i hopts)))))
                      (and o
                           (not (string-empty-p (zellij-send--askq-squash
                                                 (plist-get o :label))))
                           (string-prefix-p (zellij-send--askq-squash
                                             (plist-get o :label))
                                            label))))
                  (number-sequence 0 (1- (length hopts))))))
        q
      (let ((new (copy-sequence q)))
        (setq new (plist-put new :question (or (alist-get 'question h)
                                               (plist-get q :question))))
        (plist-put new :options
                   (mapcar (lambda (o)
                             (let ((ho (nth (1- (plist-get o :num)) hopts)))
                               (if (not ho)
                                   o
                                 (let ((o (copy-sequence o)))
                                   (setq o (plist-put o :label (alist-get 'label ho)))
                                   (plist-put o :desc (or (alist-get 'description ho)
                                                          (plist-get o :desc)))))))
                           opts))))))

;;; セッションの状態と操作（公開 API）

;; 本体の外のコード（ダッシュボード）は、黒板のバッファローカル変数や内部関数を
;; 直接読まずにここを通す。依存は dashboard → 本体の一方向のまま。
;;
;; 状態（`prompt'・`working'・`idle'）の導出もここに置く。かつてはダッシュボードが
;; `zellij-send--hook-state' にスピナーの照合とフックの失効判定を被せて自前で
;; 導いていた。どれも zellij を呼ばない——読むのは subscribe が記録した画面と
;; 変化時刻、フックが知らせた状態だけ。
;; 「完了」（見ていない間に作業が終わった）はウィンドウの可視性で決まる表示側の
;; 概念なので、ここでは扱わない。

(define-obsolete-variable-alias 'zellij-send-dashboard-working-regexp
  'zellij-send-working-regexp "0.1.0")

(defcustom zellij-send-working-regexp
  "esc to \\(?:interrupt\\|cancel\\)\\|^[^[:space:]] [^[:space:]]+… ([0-9]+[smh]"
  "AI が処理中であることを示す、画面上のスピナー行の正規表現。

CLI ごとの文言（すべて実測）:

  claude  `✳ Frobnicating… (12s · esc to interrupt)'
  codex   `• Working (2s • esc to interrupt)'
  agy     `esc to cancel'（`⣾ Generating...' などのスピナーと同時に出る）

**agy だけ cancel** なので両方を拾う。ただし**本文をそのまま流し込んで
いる間はこの行が出ない**ため、これだけでは処理中を取りこぼす
（`zellij-send-active-window' による画面変化の検出と併用する）。

2026-10-19 実測（Claude Code v2.1.303 / zellij 0.45.1）: claude のスピナー行から
`esc to interrupt' が消え、画面のどこにも出なくなった。いまの形は

  考え中        `✽ Grooving… (4s · thinking with high effort)'
  ツール実行中  `✳ Concocting… (7s · ↓ 92 tokens)'

で、記号（✳ ✢ ✶ ✻ ✽ ·）と動詞は毎回変わる。そこで「行頭の記号 1 字 + 空白 +
語 + `…' + ` (' + 秒数」を後ろの選択肢として足した。動き出した最初の 1 秒ほどは
括弧が無い（`✢ Concocting…'）ので当たらないが、画面変化の検出が拾う。
ターン終了後に残る `✻ Cooked for 29s · done 19:51' は `…' が無いので当たらない。
字下げした本文の `… (3s' に当たらないよう、行頭の 1 字は空白以外に限る。"
  :type 'regexp
  :group 'zellij-send)

(defun zellij-send--spinner-p (screen)
  "SCREEN にスピナー行（`zellij-send-working-regexp'）があれば non-nil。
**大文字小文字を区別して照合する**。スピナーの文言は 3 つの CLI とも小文字
（`esc to interrupt' / `esc to cancel'）だが、AskUserQuestion のヒント行は
`… · Esc to cancel' と大文字で始まる。区別しないと、質問を待っている画面を
「作業中」の証拠として拾っていた。"
  ;; スピナーは画面下部にしか出ない。全体を毎回走査しないよう末尾に限定する。
  (let ((start (max 0 (- (length screen) 4000)))
        (case-fold-search nil))
    (string-match-p zellij-send-working-regexp screen start)))

(defconst zellij-send--prompt-tail-lines 80
  "選択待ちの判定（`zellij-send--screen-prompt-p'）で読む、画面の末尾の行数。
選択肢は入力欄の代わりに画面の最下部へ出るので、全体を毎回読まない
（ダッシュボードは 3 秒ごとにセッションの数だけ判定する）。

2026-10-19 実測（Claude Code v2.1.303 / codex-cli 0.160.0 / Antigravity CLI 1.4.2、
test/fixtures/）: 選択肢の塊（タブ行・Review・最初の選択肢）の先頭は、末尾から
AskUserQuestion の複数選択で 18 行、単一選択で 15 行、最終確認で 13 行、
agy の許可で 7 行、codex の選択で 3 行だった。余裕を見て 80 行にした。")

(defun zellij-send--screen-tail (screen n)
  "SCREEN の末尾 N 行を返す。N 行に満たなければ SCREEN をそのまま返す。
後ろから改行を数えるだけなので、末尾の長さに比例する。"
  (let ((pos (length screen))
        (count 0))
    (while (and pos (< count n))
      (setq pos (and (> pos 0)
                     (cl-position ?\n screen :end pos :from-end t))
            count (1+ count)))
    (if pos (substring screen (1+ pos)) screen)))

(provide 'zellij-send-parse)

;;; zellij-send-parse.el ends here
