;;; zellij-send-claude.el --- Claude Code features for zellij-send -*- lexical-binding: t -*-

;; Copyright (C) 2026 桂市兵衛
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: 桂市兵衛
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/ichibeikatura/zellij-send.el

;;; Commentary:

;; Claude Code の画面や成果物に依存する機能: transcript の表示と編集の diff、
;; スラッシュコマンドの補完、AskUserQuestion への回答、Stop フックと状態フックの受け口。
;; どの CLI で使えるかは `zellij-send-agents' の能力で決まる。

;;; Code:

(require 'zellij-send-core)

;;; transcript（Claude Code の会話履歴）

;; 画面（dump-screen / subscribe）から過去の会話は取れない。alt-screen には
;; スクロールバックが無く、送信した長文は `[Pasted text #1 +59 lines]' に
;; 畳まれて本文が画面に存在しないため。履歴は Claude Code が書く JSONL から読む。

(defun zellij-send--transcript-slug (dir)
  "作業ディレクトリ DIR に対応する Claude Code のプロジェクト名を返す。
英数字以外はすべて `-' に置き換わる（`/Users/mck/.claude' なら
`-Users-mck--claude'。2026-08-02 に実在するディレクトリ名で確認）。"
  (replace-regexp-in-string
   "[^A-Za-z0-9]" "-" (directory-file-name (expand-file-name dir))))

(defvar-local zellij-send--transcript-path nil
  "このバッファのセッションにユーザーが対応付けた transcript。")

(defvar-local zellij-send--hook-transcript-path nil
  "状態フックが知らせた、このセッションの transcript（`zellij-send--on-claude-hook'）。
フックは ZELLIJ_SESSION_NAME / ZELLIJ_PANE_ID で黒板を特定したうえで
Claude Code 自身の `transcript_path' を渡すので、更新日時からの推測ではない。
ユーザーが選んだ `zellij-send--transcript-path' があればそちらを優先する。")

(defun zellij-send--transcript-first-user (text)
  "TEXT（JSONL の断片）にある最初のユーザー発言を 1 行にして返す。
タグ（`<command-name>' など）と改行は落とす。ツールの結果（role が
user でも発言ではない）と、スラッシュコマンドの注意書き
（`<local-command-caveat>' の行。中身は毎回同じ英文）は飛ばす。
無ければ nil。"
  (let (found)
    (dolist (line (split-string text "\n" t))
      (when (and (null found)
                 (string-match-p "\"type\":\"user\"" line)
                 (not (string-match-p "\"tool_result\"" line))
                 (not (string-match-p "local-command-caveat" line)))
        (let* ((obj (ignore-errors
                      (json-parse-string line :object-type 'alist
                                         :array-type 'list
                                         :null-object nil :false-object nil)))
               (body (and obj (zellij-send--transcript-text
                               (alist-get 'content
                                          (alist-get 'message obj))))))
          (when (stringp body)
            (setq body (string-trim
                        (replace-regexp-in-string
                         "[ \t\n\r]+" " "
                         (replace-regexp-in-string "<[^>]*>" " " body))))
            (unless (string-empty-p body) (setq found body))))))
    found))

(defun zellij-send--transcript-label (title time bytes)
  "transcript 1 本の候補行を作る。TITLE は長ければ切り詰める。"
  (format "%s  %8s  %s"
          (format-time-string "%m-%d %H:%M" time)
          (zellij-send--transcript-size bytes)
          (truncate-string-to-width title 60 nil nil "…")))

(defun zellij-send--transcript-peek (file tail)
  "FILE の先頭（TAIL が nil）または末尾（非 nil）を文字列で返す。
読む長さは `zellij-send-transcript-peek-bytes'。"
  (let* ((size (or (file-attribute-size (file-attributes file)) 0))
         (n zellij-send-transcript-peek-bytes)
         (beg (if tail (max 0 (- size n)) 0))
         (end (if tail size (min size n))))
    (with-temp-buffer
      (ignore-errors (insert-file-contents file nil beg end))
      (buffer-string))))

(defun zellij-send--transcript-title (file)
  "FILE の会話の題名を返す。ai-title → 最初の発言 → `(題名なし)' の順。"
  (or (zellij-send--transcript-ai-title (zellij-send--transcript-peek file t))
      (zellij-send--transcript-first-user (zellij-send--transcript-peek file nil))
      "(題名なし)"))

(defun zellij-send--transcript-candidates (files)
  "FILES を新しい順に並べ、(候補行 . パス) の alist にする。
候補行が重なると選べないので、重なったものには UUID を足す。"
  (let ((rows (sort (mapcar (lambda (f)
                              (let ((a (file-attributes f)))
                                (list f
                                      (file-attribute-modification-time a)
                                      (or (file-attribute-size a) 0))))
                            files)
                    (lambda (a b) (time-less-p (nth 1 b) (nth 1 a)))))
        out)
    (dolist (row rows)
      (let ((label (zellij-send--transcript-label
                    (zellij-send--transcript-title (nth 0 row))
                    (nth 1 row) (nth 2 row))))
        (when (assoc label out)
          (setq label (format "%s  [%s]" label (file-name-base (nth 0 row)))))
        (push (cons label (nth 0 row)) out)))
    (nreverse out)))

(defun zellij-send--transcript-table (cands)
  "CANDS（(候補行 . パス)）を並べ替えない補完表にする。
新しい順に並べてあるので、補完 UI の五十音順に崩されないようにする。"
  (lambda (str pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action cands str pred))))

(defun zellij-send--transcript-file (dir &optional reselect)
  "DIR 内の transcript を明示的に選び、バッファごとに保持する。
RESELECT が非 nil なら選び直す。候補は更新日時の新しい順に並べ、
`MM-DD HH:MM  サイズ  題名' の形で見せる（題名は JSONL の ai-title）。
並べるだけで、更新日時から所属を推測して自動で選ぶことはしない。

ユーザーが選んでいなければ、状態フックが知らせた transcript
（`zellij-send--hook-transcript-path'）を聞かずに使う。"
  (cond
   ((and (not reselect) zellij-send--transcript-path)
    (if (file-readable-p zellij-send--transcript-path)
        zellij-send--transcript-path
      (user-error "選択済みの履歴がありません。M-x zellij-send-select-transcript で選び直してください")))
   ((and (not reselect) zellij-send--hook-transcript-path
         (file-readable-p zellij-send--hook-transcript-path))
    zellij-send--hook-transcript-path)
   (t
    (let* ((proj (expand-file-name (zellij-send--transcript-slug dir)
                                   zellij-send-transcript-dir))
           (files (and (file-directory-p proj)
                       (directory-files proj t "\\.jsonl\\'"))))
      (when files
        (let* ((cands (zellij-send--transcript-candidates files))
               (choice (completing-read
                        (format "%s の会話履歴（新しい順）: "
                                (or zellij-send--session "このセッション"))
                        (zellij-send--transcript-table cands)
                        nil t)))
          (setq zellij-send--transcript-path (cdr (assoc choice cands)))))))))

(defun zellij-send-select-transcript ()
  "現在のセッションに対応する Claude transcript を選び直す。
候補は会話の題名で選ぶ。対応付けはこのバッファが生きている間保持し、
状態フックが知らせた transcript より優先する。"
  (interactive)
  (zellij-send--assert-session)
  (unless (zellij-send--capable-p 'transcript)
    (user-error "Claude Code のセッションで使用してください"))
  (unless (zellij-send--transcript-file default-directory t)
    (user-error "履歴を選べませんでした（このディレクトリに transcript が無いか、選択を中止しました）")))

;;;; 直近の編集を diff で見る

(defun zellij-send--edit-diff (edit &optional dir)
  "EDIT（`zellij-send--transcript-edits' の要素）を unified diff の文字列にする。
DIR の中のファイルは DIR からの相対パスで出す。
Write は書き込んだ内容全体を追加として出す（上書きなら前の内容は
transcript の tool_use に無いので出せない。見出しにそう書く）。"
  (let* ((file (plist-get edit :file))
         ;; `file-in-directory-p' は実在するディレクトリでしか判定できないので
         ;; 文字列で比べる
         (inside (and dir (string-prefix-p
                           (file-name-as-directory (expand-file-name dir))
                           (expand-file-name file))))
         (name (if inside (file-relative-name file dir) file))
         ;; diff-mode は a/ b/ を外して default-directory から探す。
         ;; DIR の外のファイルは絶対パスのまま出す
         (a (if inside (concat "a/" name) name))
         (b (if inside (concat "b/" name) name)))
    (if (equal (plist-get edit :name) "Write")
        (let ((n (zellij-send--diff-lines (plist-get edit :content))))
          (concat
           (format "Write: %s（ファイル全体。上書き前の内容は表示できません）\n" name)
           "--- /dev/null\n"
           (format "+++ %s\n" b)
           (format "@@ -0,0 +1,%d @@\n" (length (car n)))
           (mapconcat (lambda (l) (concat "+" l "\n")) (car n) "")
           (if (> (cdr n) 0) (format "\\ 残り %d 行は省略\n" (cdr n)) "")))
      (concat
       (format "%s: %s\n" (plist-get edit :name) name)
       (format "--- %s\n+++ %s\n" a b)
       (zellij-send--diff-hunk (plist-get edit :old) (plist-get edit :new))))))

(defun zellij-send-show-last-diff ()
  "Claude Code の直近の編集（Edit / Write / MultiEdit）を diff で表示する。
直近のターン（最後のあなたの発言より後）の編集をすべて、
`*zellij-diff-SESSION*' に `diff-mode' で出す。そのターンに編集が無ければ
最後の編集 1 件を出す。ファイルは書き換えない。

読むのは transcript の tool_use（`zellij-send--transcript-file' で選んだもの）。
編集が見つからないときは「対象なし」と言って終わる。Claude Code 専用。"
  (interactive)
  (zellij-send--assert-session)
  (unless (zellij-send--capable-p 'transcript)
    (user-error "直近の編集の表示は Claude Code 専用です（いまは %s）"
                (or (zellij-send--buffer-command) "コマンド不明")))
  (let* ((session zellij-send--session)
         (dir default-directory)
         (file (zellij-send--transcript-file dir))
         (edits (and file
                     (zellij-send--transcript-edits
                      (with-temp-buffer
                        (insert-file-contents file)
                        (buffer-string))))))
    (cond
     ((null file) (message "transcript が見つかりません"))
     ((null edits) (message "直近の編集はありません（対象なし）"))
     (t
      (let ((buf (get-buffer-create (format "*zellij-diff-%s*" session))))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (mapconcat (lambda (e) (zellij-send--edit-diff e dir))
                               edits "\n"))
            (diff-mode)
            (setq default-directory dir)
            (setq buffer-read-only t)
            (goto-char (point-min))))
        (display-buffer buf)
        (message "直近の編集 %d 件を表示しました" (length edits)))))))

;;; Stop フックハンドラ

;;;###autoload
(defun zellij-send--on-claude-stop (&optional session pane &rest _later)
  "Claude Code 停止時に、黒板を dump-screen で取り直す。
~/.claude/hooks/stop-zellij-send.sh から emacsclient 経由で呼ばれる。

SESSION と PANE はフックが継承した ZELLIJ_SESSION_NAME / ZELLIJ_PANE_ID。
渡されたらそのセッションの黒板だけを対象にする（`zellij-send--hook-buffer'）。
渡されない（古いスクリプト・zellij の外の Claude Code）ときは全部の黒板が対象。

**subscribe が生きている黒板は取り直さない**。画面は subscribe で常に最新に
なっているので、Stop のたびに全セッションへ `dump-screen' を投げるのは
zellij を呼ぶだけ無駄だった。取り直すのは subscribe が切れている黒板だけ
（再接続をあきらめた後の取りこぼしを拾う）。ユーザーがクリア・編集中の
黒板は従来どおり更新しない。_LATER は将来のスクリプトが足す引数の受け皿。"
  (dolist (buf (if (and (stringp session) (not (string-empty-p session)))
                   (delq nil (list (zellij-send--hook-buffer session pane)))
                 (buffer-list)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (eq major-mode 'zellij-send-mode)
                   zellij-send--session
                   (not (zellij-send--subscribe-live-p))
                   (not zellij-send--user-cleared)
                   (not (buffer-modified-p)))
          (zellij-send--dump-screen-async
           zellij-send--session
           (lambda (content)
             (when (and content
                        (not zellij-send--user-cleared)
                        (not (buffer-modified-p)))
               (funcall zellij-send--display-function content))))))))
  nil)

(defun zellij-send--subscribe-live-p ()
  "カレントの黒板の subscribe が生きていて、画面を受け取れていれば non-nil。
プロセスが生きていても初回イベントがまだなら、繋がっているとは言えない
（存在しないセッションでも subscribe は黙って生き続ける）。"
  (and zellij-send--subscribe-process
       (process-live-p zellij-send--subscribe-process)
       zellij-send--last-event-time
       (equal zellij-send--subscribe-pane-id zellij-send--pane-id)))

;;; 状態フック（Claude Code の hooks から状態を受け取る）

;; 画面の形に頼らずに「作業中」「選択待ち」を知るための経路。README の
;; state-zellij-send.sh が、Claude Code の hooks の JSON を受けて
;; `zellij-send--on-claude-hook' を emacsclient で呼ぶ。フックは任意で、
;; 未設定なら `zellij-send--hook-state' は nil のままでダッシュボードは
;; 画面解析だけで動く。
;;
;; 黒板の特定には、フックのプロセスが zellij のペインから継承する
;; ZELLIJ_SESSION_NAME / ZELLIJ_PANE_ID を使う（2026-10-19、zellij 0.45.1 の
;; ペインで動く Claude Code の環境に両方あることを確認。ZELLIJ_PANE_ID は
;; 数字だけで、`terminal_N' の N に当たる）。cwd では同じディレクトリの
;; エージェントを見分けられない。
;;
;; フックのイベント（2026-10-19 に公式の hooks リファレンスで確認）:
;; - UserPromptSubmit                       → 作業中
;; - PreToolUse（AskUserQuestion）・PermissionRequest・
;;   Notification（permission_prompt / elicitation_dialog）→ 選択待ち
;; - PostToolUse / PostToolUseFailure       → 作業中（選択が済んだ）
;; - Stop / StopFailure・Notification（idle_prompt）→ 待機
;; **Stop はユーザーが Esc で中断したときには来ない**（リファレンスに明記）。
;; 作業中のまま残りうるので、状態を導く `zellij-send--hook-status' は画面が
;; 止まってしばらく経ったら信用しない。Emacs から中断したとき
;; （`zellij-send-interrupt'）はそれを待たずにすぐ消す。

(defvar-local zellij-send--hook-state nil
  "フックから受け取ったこのセッションの状態。nil なら受け取っていない。
`working'（作業中）・`waiting'（選択・許可待ち）・`idle'（ターン終了）のどれか。")

(defvar-local zellij-send--hook-state-time nil
  "`zellij-send--hook-state' を受け取った時刻（`float-time'）。")

(defvar-local zellij-send--hook-questions nil
  "PreToolUse フックが知らせた、直近の AskUserQuestion の質問。
tool_input の questions をそのまま alist にしたもの（各要素は question・
header・multiSelect・options（label・description））。回答の画面を読むときに
`zellij-send--askq-enrich' がラベルと説明の正本として使う。")

(defun zellij-send--hook-event-state (event detail)
  "フックの EVENT（hook_event_name）と DETAIL から状態を返す。対象外なら nil。
DETAIL は PreToolUse などでは tool_name、Notification では notification_type。"
  (pcase event
    ("UserPromptSubmit" 'working)
    ("PreToolUse" (and (equal detail "AskUserQuestion") 'waiting))
    ("PermissionRequest" 'waiting)
    ((or "PostToolUse" "PostToolUseFailure") 'working)
    ((or "Stop" "StopFailure") 'idle)
    ("Notification"
     (pcase detail
       ((or "permission_prompt" "elicitation_dialog") 'waiting)
       ("idle_prompt" 'idle)))))

(defun zellij-send--hook-buffer (session pane)
  "SESSION（とペイン番号 PANE）に対応する黒板バッファを返す。無ければ nil。
黒板の pane-id が分かっていて PANE と食い違うなら、同じセッションの
別のペイン（シェルなど）からのフックなので対象にしない。"
  (seq-find
   (lambda (buf)
     (and (eq (buffer-local-value 'major-mode buf) 'zellij-send-mode)
          (equal (buffer-local-value 'zellij-send--session buf) session)
          (let ((id (buffer-local-value 'zellij-send--pane-id buf)))
            (or (null id) (null pane) (string-empty-p pane)
                (equal id (concat "terminal_" pane))))))
   (buffer-list)))

(defun zellij-send--hook-clear ()
  "カレントの黒板のフック状態を捨てる（画面解析に戻す）。"
  (setq zellij-send--hook-state nil
        zellij-send--hook-state-time nil))

;;;###autoload
(defun zellij-send--on-claude-hook (session pane event &optional detail transcript
                                            questions &rest _later)
  "Claude Code のフックから状態を受け取る（state-zellij-send.sh が呼ぶ）。
SESSION と PANE はフックが継承した ZELLIJ_SESSION_NAME / ZELLIJ_PANE_ID、
EVENT は hook_event_name、DETAIL は tool_name か notification_type、
TRANSCRIPT はフックの transcript_path、QUESTIONS は AskUserQuestion の
PreToolUse のときだけ tool_input の questions（JSON の文字列）。
対応する黒板の `zellij-send--hook-state'・`zellij-send--hook-transcript-path'・
`zellij-send--hook-questions' を立てるだけで、zellij は呼ばない。
emacsclient から呼ばれるので、すぐに返る。

_LATER は将来のスクリプトが足す引数の受け皿。フックのスクリプトだけ
新しくなると引数が増え、引数の数が合わずに毎回黙って失敗していた
（2026-10-19、elpaca の古いビルドで実際に起きた）。"
  (let ((state (zellij-send--hook-event-state event detail))
        (buf (zellij-send--hook-buffer session pane)))
    (when buf
      (with-current-buffer buf
        (when state
          (setq zellij-send--hook-state state
                zellij-send--hook-state-time (float-time)))
        ;; /clear で会話が替わると transcript も替わるので、毎回取り直す
        (when (and (stringp transcript)
                   (string-suffix-p ".jsonl" transcript)
                   (file-readable-p transcript))
          (setq zellij-send--hook-transcript-path transcript))
        (when (and (equal event "PreToolUse")
                   (equal detail "AskUserQuestion")
                   (stringp questions)
                   (not (string-empty-p questions)))
          (let ((parsed (ignore-errors
                          (json-parse-string questions :object-type 'alist
                                             :array-type 'list
                                             :null-object nil
                                             :false-object nil))))
            (when (and parsed (listp parsed))
              (setq zellij-send--hook-questions parsed))))))
    nil))

;;; Claude Code コマンド

;; `/compact' と `/clear' はメニューから外した（`zellij-send-slash-command' で
;; どのスラッシュコマンドも送れるようになったため）。M-x とダッシュボードの
;; `c'（`zellij-send-dashboard-compact')から使うのでコマンド自体は残す。

(defun zellij-send--send-known-slash (command cap done-message)
  "COMMAND を送る。能力 CAP を持つと確定していなければ送らずに `user-error'。
DONE-MESSAGE は送信に成功したときのメッセージ。
**「効いた」ではなく「送った」と書くこと**——画面を読んでいないので
受け取った側が実行したかどうかは判らない。
「テキストを送るだけだからどの CLI でも許可」は妥当ではない——受け取った
側は本文として解釈し、そのまま作業を始めてしまう（`zellij-send-agents'）。"
  (zellij-send--assert-session)
  (zellij-send--assert-capability cap)
  (zellij-send--send zellij-send--session command
                     (lambda (ok) (when ok (message "%s" done-message)))))

(defun zellij-send-compact ()
  "セッションに /compact を送信してコンテキストを圧縮させる。
メニューには無い（`C-c C-a' → `/' か M-x、ダッシュボードの `c'）。"
  (interactive)
  (zellij-send--send-known-slash "/compact" 'compact "/compact を送信しました"))

(defun zellij-send-cc-clear ()
  "セッションに /clear を送信してコンテキストをリセットさせる。
メニューには無い（`C-c C-a' → `/' か M-x）。"
  (interactive)
  (zellij-send--send-known-slash "/clear" 'clear "/clear を送信しました"))

(defun zellij-send-interrupt ()
  "実行中の処理を中断する（対象ペインに Esc を送る）。
状態は問わない。ダッシュボードの状態表示は数秒古いことがあり、
「作業中に見えない」ことを理由に中断を拒むと止められなくなるため。

**Esc が中断として効くかは相手次第**なので、メッセージは
「Esc を送信しました」に留める。効かないときはキー透過モード
（\\[zellij-send-keys-mode]）で直接操作する。"
  (interactive)
  (zellij-send--assert-session)
  ;; 中断では Stop フックが来ないので、フックの「作業中」を捨てて
  ;; 画面解析に戻す（`zellij-send--on-claude-hook' の前の注記）
  (zellij-send--hook-clear)
  (let ((session zellij-send--session))
    (zellij-send--send-keys
     session '(27)
     (lambda (exit)
       ;; 画面を読んでいないので「中断できた」とは言えない。Esc が
       ;; 何に効くかは相手の状態次第（codex は空の入力欄で Esc 2 回が
       ;; 過去メッセージの編集になる）。送った事実だけを報告する
       (if (zerop exit)
           (message "Esc を送信しました → [%s]" session)
         (message "Esc の送信に失敗しました (exit: %d)" exit))))))

(defcustom zellij-send-progress-file-default "AGENTS.md"
  "`zellij-send-agents' で `:progress-file' を持たないエージェントで使うファイル名。"
  :type 'string
  :group 'zellij-send)

(defcustom zellij-send-progress-log-file ".zellij-send/worklog-%Y-%m-%d.md"
  "`zellij-send-save-progress' に `\\[universal-argument]' を付けたときに
作業ログを書かせるファイル（セッション作業ディレクトリからの相対）。
`format-time-string' の書式で、依頼を送った時点の日付が入る。

作業ログを CLAUDE.md 等（`zellij-send-agents' の `:progress-file'）に書かせない
ための受け皿。あちらはエージェントが毎回読み込むので、その場の経過を
積むほどコンテキストを食う。日付で分けたファイルなら、要らなくなった
日の分をまとめて捨てられる。"
  :type 'string
  :group 'zellij-send)

(defun zellij-send--progress-file ()
  "このバッファのエージェントに作業内容を書かせるファイル名を返す。"
  (or (zellij-send--agent-get (zellij-send--buffer-command) :progress-file)
      zellij-send-progress-file-default))

(defun zellij-send--progress-request (file &optional log-file)
  "`zellij-send-save-progress' がエージェントに送る依頼文を返す。
FILE は恒久的な決定事項を置くファイル（CLAUDE.md など）。LOG-FILE が
非 nil なら、作業ログをそちらに書かせる依頼にする。

FILE には**追記させない**。追記だと回を重ねるごとに単調に伸び、
エージェントが毎回読み込むコンテキストを食い潰す（この機能を使うほど
CLAUDE.md が肥大する構造だった）。更新として、重複は書き直させ、
古い記述は消させ、その場の作業ログは書かせない。"
  (if log-file
      (format (concat "ここまでの作業ログ（やったこと・途中の判断・未解決の点）を "
                      "%s に書いて。ファイルが無ければ作り、あれば末尾に足す。"
                      "%s には書かないで。")
              log-file file)
    (format (concat "ここまでの作業で決まった恒久的なこと（動かせない制約・"
                    "設計判断とその理由・禁止事項）だけを %s に反映して。"
                    "追記ではなく更新として扱うこと: 既存の記述と重なる内容は"
                    "その箇所を書き直してまとめ、古くなった記述は消す。"
                    "作業の経過・やったことの時系列・TODO の消化記録は書かない。")
            file)))

(defun zellij-send-save-progress (&optional log)
  "決定事項を記録するよう依頼する。
書かせる先はエージェントごとに変える（`zellij-send-agents' の `:progress-file'）。
依頼は**追記ではなく更新**——恒久的な決定事項だけを反映させ、重複は
まとめ、古い記述は消させる（`zellij-send--progress-request'）。

LOG（`\\[universal-argument]'）を付けると、その場の作業ログを
`zellij-send-progress-log-file'（日付付き）に書かせる。CLAUDE.md 等には
書かせない。"
  (interactive "P")
  (zellij-send--assert-session)
  (let* ((file (zellij-send--progress-file))
         (log-file (and log (format-time-string zellij-send-progress-log-file)))
         (target (or log-file file)))
    (zellij-send--send zellij-send--session
                       (zellij-send--progress-request file log-file)
                       (lambda (ok)
                         (when ok (message "%s への記録を依頼しました" target))))))

;;; スラッシュコマンド（Claude Code の /コマンド全部）

;; 2026-07-29 に Claude Code v2.1.220 + zellij 0.44.3（320 桁の背景セッション）で
;; 実測した補完メニューの仕様。**同じ調査を繰り返さないこと。**
;;
;;   /doctor            Health-check the user's Claude Code setup and fix issues: …
;;                      MCP servers, and plugins versus their context cost and …   ← 折り返し
;;   /ndl               国立国会図書館(NDL)のデジタルコレクション…  (user)
;;   ────────────────────────────────────────────────────────────── ↯ ─   ← 入力枠の上罫線
;;   ❯ /
;;   ──────────────────────────────────────────────────────────────
;;
;; - 一覧は入力欄に `/` を打つと**入力枠のすぐ上**に出る。1 件 `  /name  説明`。
;;   説明は折り返して深いインデントの続き行になる
;; - **メニューは 4 行しか出ない**。説明が折り返すと 2 件しか見えないので、
;;   全件（実測 102 件）を得るには ↓ を送りながら読み続けるしかない。
;;   ここだけは往復が要るので、一度取ったらバッファに覚える（C-u で取り直し）
;; - ↓ はカーソルを 1 件動かす。**カーソルが最下段に来て初めて窓が 1 件ずつ動く**。
;;   つまり定常状態では「見えている件数 - 1」回の ↓ で 1 件重なりを残して送れる。
;;   一括で大きく飛ばすと取りこぼすので、必ず見えている件数から毎回決めること
;; - `/name ` まで打つと**引数のヒントがゴースト表示**される
;;   （`/model  [model]`、`/effort  [low|medium|high|xhigh|max|ultracode|auto]`）。
;;   引数を取らないコマンドは末尾の空白ごと消えて `/name` のまま。これが
;;   「引数が要るか」の唯一の判定材料
;; - 入力欄は **Ctrl+U（21）で消す。Esc では消えない**（実測。Esc を送っても
;;   `/c` が残り、続けて `/` を打つと `/c/` になってメニューが出なくなった）
;; - `paste` で送ったテキストは補完メニューを開かない。`/effort high` を paste して
;;   Enter でそのまま実行できる（既存の `zellij-send--send' がそのまま使える）
;;
;; ペインの入力欄を実際に打って調べるので、**入力欄が空でないときは何もしない**。
;; ユーザーがターミナル側で書きかけたテキストを Ctrl+U で消してしまわないため。
;;
;; 2026-10-19 実測（Claude Code v2.1.303 / zellij 0.45.1、320 桁の背景セッション。
;; 画面そのものは test/fixtures/slash-*.txt）:
;; - **選択中の項目の行頭に `❯' が付く**（`  ❯ /ndl   国立国会図書館…'）。
;;   `zellij-send--slash-entry-regexp' はこの行に当たらず、そこで読むのをやめる
;;   ので、一覧が欠ける（test/zellij-send-parse-test.el の失敗扱いの 4 本）
;;   → 同日、`❯' を読み飛ばすよう正規表現を直した
;; - 1 行で収まる項目なら 5 件見えた（`/install-github-app' から `/login' まで）
;; - 入力枠の上罫線は `─' だけの行になった（`↯' は無い）
;; - 末尾で ↓ を押すと先頭へ、先頭で ↑ を押すと末尾へ回り込む
;;   （`/' の直後に ↑ 1 回で最後の `/workflow-authoring' に移った）

(defcustom zellij-send-slash-settle-delay 0.25
  "スラッシュコマンドの操作で、キーを送ってから画面を読み直すまでの待ち時間（秒）。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-slash-max-rounds 200
  "コマンド一覧を集めるときにメニューを送る回数の上限。
実測 102 件を 1 回 3 件前後で送るので通常は 40 回程度で終わる。
画面を読み違えて空回りしても必ず止まるための歯止め。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-slash-arg-max-rounds 40
  "引数の候補メニューを集めるときに ↓ を送る回数の上限。
`/plugin install' のように候補が数百あるコマンドで延々とキーを送り続けない
ための歯止め。ここで打ち切った一覧は「一部」として扱い、キャッシュしない
（欠けた一覧を焼き付けると以後ずっと欠けたまま出る）。候補に無い値も
そのまま打てるので、打ち切っても行き止まりにはならない。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-slash-prefetch t
  "non-nil なら、黒板バッファを開いた少し後に一覧を黙って取りに行く。
初回の `zellij-send-slash-command' を待ち時間ゼロにするための先読み。
取得はペインに実際にキーを送るので、ペインを一切触られたくない環境では
nil にする。"
  :type 'boolean
  :group 'zellij-send)

(defcustom zellij-send-slash-prefetch-delay 5
  "先読みを始めるまでの待ち時間（秒）。
起動直後の claude はまだ入力を受け付けないことがあるので少し置く。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-slash-prefetch-retries 4
  "先読みをやり直す回数の上限。
信頼確認（trust プロンプト）などで入力欄が空でないときは取得を諦めるので、
少し置いて何度か試す。使い切ったら諦めて、初回の
`zellij-send-slash-command' で取ることになる。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-slash-cache-directory
  (locate-user-emacs-file "zellij-send/slash-commands/")
  "スラッシュコマンド一覧をディスクに保存するディレクトリ。nil なら保存しない。
全体用の一覧を 1 ファイル（と、全体用で済まないディレクトリの分を 1 ファイルずつ）
置き、Emacs を再起動した後もそれを読む（`zellij-send--slash-cached'）。

一覧の取得はペインの入力欄を実際に打つうえ 8〜10 秒かかる（実測 102 件）。
メモリにだけ持つと、Emacs を起動するたびに全セッションで打ち込みが走る。
保存した一覧が古くなったら（`zellij-send--slash-cache-valid-p'）黙って
取り直す。`\\[universal-argument] \\[zellij-send-slash-command]' はファイルも捨てて取り直す。"
  :type '(choice (const :tag "保存しない" nil) directory)
  :group 'zellij-send)

(defcustom zellij-send-slash-cache-max-age (* 7 24 60 60)
  "保存したスラッシュコマンド一覧を信用する期間（秒）。nil なら期限なし。
claude 本体の更新やスキルの追加は `zellij-send--slash-cache-fingerprint' でも
見ているが、拾えない変化（プラグイン内のコマンドの更新など）もあるので
期限でも取り直す。"
  :type '(choice (const :tag "期限なし" nil) natnum)
  :group 'zellij-send)

(defvar zellij-send--slash-cache-table (make-hash-table :test 'equal)
  "スラッシュコマンド一覧の控え。
キーは作業ディレクトリの絶対パスか `zellij-send--slash-global-key'、値は plist
(:entries ENTRIES :time 取得時刻 :fingerprint FP)。ENTRIES は
((\"/name\" . \"説明\") ...)、FP は `zellij-send--slash-cache-fingerprint'
（全体用は `zellij-send--slash-global-fingerprint'）の値。
ディスク（`zellij-send-slash-cache-directory'）から読んだものもここに入る。")

;; 一覧を全体で共有する（2026-10-19）。
;;
;; 一覧の取得はペインの入力欄を実際に打つうえ 8〜10 秒かかる。かつては作業
;; ディレクトリごとに取っていたので、10 プロジェクトで同じ 100 件余りを 10 回
;; 打ち込んでいた。ところが中身のうちディレクトリで変わるのは、そのプロジェクト
;; 自身の `.claude/commands' と `.claude/skills' だけで、組み込み・`~/.claude' の
;; コマンドとスキル・プラグイン・claude.ai から同期したスキルはどこでも同じ。
;; そこで:
;;
;; - 取った一覧から、そのプロジェクトのコマンドとスキル（ファイルから列挙）を
;;   引いたものを全体用として 1 つだけ持つ（`zellij-send--slash-global-key'）
;; - 別のディレクトリでは、全体用にそのプロジェクトの分をファイルから足して
;;   作る。ペインには打たない（`zellij-send--slash-project-entries'）
;; - ファイルから決めきれないプロジェクト（`zellij-send--slash-simple-project-p'
;;   が nil）は、推測せず従来どおりディレクトリごとにペインから取る
;;
;; 出どころ（組み込み・ユーザー・プラグイン）はメニューの説明からは見分けられない
;; （説明はペイン幅で切れ、印が付くのは一部だけ）ので、引き算で全体用を作る。
;; 未確認の前提: 組み込みのコマンドはディレクトリで変わらない。違っても補完は
;; 一覧に無い名前も打てるので、候補が 1 つ多い・少ない程度で済む。

(defconst zellij-send--slash-cache-version 2
  "保存する一覧の形式の版。指紋に入れるので、上げると保存済みの一覧はすべて取り直しになる。
2（2026-10-19）: 全体用の一覧を足した。あわせて、補完メニューの選択中の行の
`❯' を読めなかった頃（v2.1.303 の画面に対応する前）に 1 件しか読めないまま
保存された一覧を捨てる（実際に 2 つのディレクトリで 1 件の一覧が残っていた）。")

(defconst zellij-send--slash-global-key "*global*"
  "全体用の一覧のキー（`zellij-send--slash-cache-table' とディスクのファイル）。")

(defun zellij-send--slash-cache-key ()
  "カレントバッファのスラッシュコマンド一覧のキー（作業ディレクトリ）を返す。"
  (directory-file-name (file-truename default-directory)))

(defun zellij-send--slash-mtime (file)
  "FILE の最終更新時刻を `float-time' で返す。無ければ nil。"
  (let ((attrs (file-attributes file)))
    (and attrs (float-time (file-attribute-modification-time attrs)))))

(defun zellij-send--slash-dir-stamp (dir)
  "DIR とその直下の項目のうち、最も新しい最終更新時刻を返す。無ければ nil。
スキルはディレクトリごと足すので、直下の項目の更新で増減と書き換えを拾う。"
  (when (file-directory-p dir)
    (apply #'max
           (delq nil (cons (zellij-send--slash-mtime dir)
                           (mapcar #'zellij-send--slash-mtime
                                   (directory-files dir t "\\`[^.]")))))))

(defun zellij-send--slash-global-fingerprint ()
  "全体用の一覧が変わったかを見分けるための値を返す。
一覧を決める材料のうち、ディレクトリによらないものをファイルの時刻で表す
（zellij も claude も呼ばない）:

- 保存の形式の版（`zellij-send--slash-cache-version'）
- claude の実行ファイル（実体のパスと更新時刻。版が上がると変わる）
- `~/.claude' の `commands' / `skills'
- `~/.claude/plugins/installed_plugins.json'（プラグインの増減）

値は `equal' で比べるので、数値と文字列だけで作る。"
  (let* ((exe (executable-find
               (or (car (split-string (or zellij-send--command
                                          zellij-send-default-command)
                                      nil t))
                   zellij-send-default-command)))
         (true (and exe (file-truename exe)))
         (home (expand-file-name "~/.claude/")))
    (list :version zellij-send--slash-cache-version
          :claude (and true (list true (zellij-send--slash-mtime true)))
          :dirs (mapcar (lambda (dir) (cons dir (zellij-send--slash-dir-stamp dir)))
                        (list (expand-file-name "commands" home)
                              (expand-file-name "skills" home)))
          :plugins (zellij-send--slash-mtime
                    (expand-file-name "plugins/installed_plugins.json" home)))))

(defun zellij-send--slash-cache-fingerprint ()
  "カレントバッファのディレクトリの一覧が変わったかを見分けるための値を返す。
全体用の材料（`zellij-send--slash-global-fingerprint'）に、プロジェクトの
`.claude/commands' / `.claude/skills' の時刻を足したもの。"
  (append (zellij-send--slash-global-fingerprint)
          (list :project
                (mapcar (lambda (dir) (cons dir (zellij-send--slash-dir-stamp dir)))
                        (list (expand-file-name ".claude/commands" default-directory)
                              (expand-file-name ".claude/skills" default-directory))))))

(defun zellij-send--slash-frontmatter (file)
  "FILE の先頭の YAML frontmatter から (NAME . DESCRIPTION) を返す。
無いものは nil。読むのは `name:' と `description:' だけで、`>-' / `|' の
複数行は空白でつないで 1 行にする（補完の注釈に出すだけなので厳密でなくてよい）。"
  (with-temp-buffer
    (ignore-errors (insert-file-contents file nil 0 16384))
    (goto-char (point-min))
    (when (looking-at "---[ \t]*$")
      (forward-line 1)
      (let (name desc)
        (while (and (not (eobp)) (not (looking-at "---[ \t]*$")))
          (if (looking-at "\\(name\\|description\\):[ \t]*\\(.*\\)$")
              (let ((key (match-string 1))
                    (val (string-trim (match-string 2))))
                (forward-line 1)
                (when (member val '(">" ">-" ">+" "|" "|-" "|+"))
                  (let (parts)
                    (while (and (not (eobp)) (looking-at "[ \t]+\\(.*\\)$"))
                      (push (string-trim (match-string 1)) parts)
                      (forward-line 1))
                    (setq val (string-join (nreverse parts) " "))))
                (when (string-match "\\`\\([\"']\\)\\(.*\\)\\1\\'" val)
                  (setq val (match-string 2 val)))
                (if (equal key "name") (setq name val) (setq desc val)))
            (forward-line 1)))
        (cons (and name (not (string-empty-p name)) name)
              (and desc (not (string-empty-p desc)) desc))))))

(defun zellij-send--slash-project-entries (dir)
  "DIR のプロジェクト自身のコマンドとスキルを ((\"/name\" . 説明) ...) で返す。
ファイルから列挙する（ペインには打たない）。`.claude/commands/NAME.md' が
`/NAME'、`.claude/skills/DIR/SKILL.md' が `/名前'（frontmatter の `name'、
無ければディレクトリ名）。説明は frontmatter の `description'、無ければ nil。"
  (let ((cmds (expand-file-name ".claude/commands" dir))
        (skills (expand-file-name ".claude/skills" dir))
        entries)
    (when (file-directory-p cmds)
      (dolist (f (directory-files cmds t "\\`[^.].*\\.md\\'"))
        (when (file-regular-p f)
          (push (cons (concat "/" (file-name-base f))
                      (cdr (zellij-send--slash-frontmatter f)))
                entries))))
    (when (file-directory-p skills)
      (dolist (d (directory-files skills t "\\`[^.]"))
        (let ((md (expand-file-name "SKILL.md" d)))
          (when (file-readable-p md)
            (let ((fm (zellij-send--slash-frontmatter md)))
              (push (cons (concat "/" (or (car fm) (file-name-nondirectory d)))
                          (cdr fm))
                    entries))))))
    (nreverse entries)))

(defun zellij-send--slash-simple-project-p (dir)
  "DIR の一覧を、全体用の一覧と DIR 自身のコマンド・スキルから作ってよければ non-nil。
ファイルから決めきれないものがあれば nil（従来どおりペインから取る）:

- `.mcp.json' がある（プロジェクトの MCP サーバのプロンプトもコマンドになる）
- `.claude/settings*.json' でプラグインを有効にしている（`enabledPlugins'）
- `.claude/commands' にサブディレクトリがある（名前の付き方を確かめていない）
- DIR より上（ホームを除く）にも `.claude/commands' か `.claude/skills' がある"
  (let* ((d (file-name-as-directory (file-truename dir)))
         (home (file-name-as-directory (file-truename "~")))
         (cmds (expand-file-name ".claude/commands" d)))
    (and (not (file-exists-p (expand-file-name ".mcp.json" d)))
         (not (seq-some
               (lambda (name)
                 (let ((f (expand-file-name name d)))
                   (and (file-readable-p f)
                        (with-temp-buffer
                          (insert-file-contents f)
                          (search-forward "enabledPlugins" nil t)))))
               '(".claude/settings.json" ".claude/settings.local.json")))
         (not (and (file-directory-p cmds)
                   (seq-some #'file-directory-p
                             (directory-files cmds t "\\`[^.]"))))
         (let ((p (file-name-directory (directory-file-name d)))
               (found nil))
           (while (and p (not found))
             (unless (equal p home)
               (setq found (or (file-directory-p (expand-file-name ".claude/commands" p))
                               (file-directory-p (expand-file-name ".claude/skills" p)))))
             (let ((up (file-name-directory (directory-file-name p))))
               (setq p (and up (not (equal up p)) up))))
           (not found)))))

(defun zellij-send--slash-merge (global project)
  "全体用の一覧 GLOBAL にプロジェクトの分 PROJECT を足して、名前順にして返す。
同じ名前はプロジェクトの方を使う。"
  (sort (append project
                (seq-remove (lambda (e) (assoc (car e) project)) global))
        (lambda (a b) (string< (car a) (car b)))))

(defun zellij-send--slash-cache-valid-p (entry fingerprint &optional now)
  "保存した ENTRY（`zellij-send--slash-cache-table' の値）がまだ使えれば non-nil。
FINGERPRINT はいまの `zellij-send--slash-cache-fingerprint'、NOW は現在時刻
（省略時は `float-time'）。取得から `zellij-send-slash-cache-max-age' 秒を
過ぎたもの、材料（FINGERPRINT）が変わったものは使えない。"
  (let ((time (plist-get entry :time))
        (max-age zellij-send-slash-cache-max-age))
    (and (plist-get entry :entries)
         (numberp time)
         (or (null max-age)
             (< (- (or now (float-time)) time) max-age))
         (equal (plist-get entry :fingerprint) fingerprint))))

(defun zellij-send--slash-cache-file (key)
  "作業ディレクトリ KEY の一覧を保存するファイルを返す。保存しないなら nil。"
  (when zellij-send-slash-cache-directory
    (expand-file-name (concat (md5 key) ".eld")
                      zellij-send-slash-cache-directory)))

(defun zellij-send--slash-cache-read (key)
  "作業ディレクトリ KEY の一覧をディスクから読む。無い・壊れていれば nil。"
  (let ((file (zellij-send--slash-cache-file key)))
    (when (and file (file-readable-p file))
      (ignore-errors
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix))
            (insert-file-contents file))
          (let ((entry (read (current-buffer))))
            ;; md5 の衝突や手で置いたファイルで別のディレクトリの一覧を使わない
            (and (equal (plist-get entry :dir) key) entry)))))))

(defun zellij-send--slash-cache-write (key entry)
  "作業ディレクトリ KEY の一覧 ENTRY をディスクに書く。失敗しても止めない。"
  (let ((file (zellij-send--slash-cache-file key)))
    (when file
      (with-demoted-errors "zellij-send: スラッシュコマンド一覧を保存できません: %S"
        (make-directory (file-name-directory file) t)
        (let ((coding-system-for-write 'utf-8-unix)
              (print-length nil)
              (print-level nil))
          (with-temp-file file
            (prin1 (plist-put (copy-sequence entry) :dir key) (current-buffer))))))))

(defun zellij-send--slash-cache-lookup (key fingerprint)
  "KEY の一覧を、FINGERPRINT で確かめてから返す。無いか古ければ nil。
メモリに無ければディスクから読む（Emacs を再起動した直後でも打ち込まずに
済むように）。古くなっていたら捨てる。"
  (let ((entry (or (gethash key zellij-send--slash-cache-table)
                   (zellij-send--slash-cache-read key))))
    (when entry
      (if (zellij-send--slash-cache-valid-p entry fingerprint)
          (progn (puthash key entry zellij-send--slash-cache-table)
                 (plist-get entry :entries))
        (remhash key zellij-send--slash-cache-table)
        nil))))

(defun zellij-send--slash-cached ()
  "カレントバッファのディレクトリの一覧を返す。無いか古ければ nil。
ディレクトリごとの一覧があればそれを、無ければ全体用の一覧にプロジェクトの
コマンドとスキルを足して作る（`zellij-send--slash-simple-project-p' のときだけ）。
呼び出し側は nil を見て取り直す。"
  (or (zellij-send--slash-cache-lookup (zellij-send--slash-cache-key)
                                       (zellij-send--slash-cache-fingerprint))
      (and (zellij-send--slash-simple-project-p default-directory)
           (let ((global (zellij-send--slash-cache-lookup
                          zellij-send--slash-global-key
                          (zellij-send--slash-global-fingerprint))))
             (and global
                  (zellij-send--slash-merge
                   global (zellij-send--slash-project-entries default-directory)))))))

(defun zellij-send--slash-cache-store (key alist fingerprint)
  "ALIST を KEY の一覧として FINGERPRINT と一緒に覚え、ディスクにも書く。"
  (let ((entry (list :entries alist :time (float-time) :fingerprint fingerprint)))
    (puthash key entry zellij-send--slash-cache-table)
    (zellij-send--slash-cache-write key entry)))

(defun zellij-send--slash-cache-put (alist)
  "カレントバッファのディレクトリで取った ALIST を覚え、ディスクにも書く。
`zellij-send--slash-simple-project-p' なら、プロジェクトのコマンドとスキルを
引いて全体用の一覧として持つ（ほかのディレクトリでも使う）。そうでなければ
ディレクトリごとに持つ。打ち切った一覧（truncated）をここに渡さないこと。"
  (if (zellij-send--slash-simple-project-p default-directory)
      (let ((project (zellij-send--slash-project-entries default-directory)))
        (zellij-send--slash-cache-store
         zellij-send--slash-global-key
         (seq-remove (lambda (e) (assoc (car e) project)) alist)
         (zellij-send--slash-global-fingerprint)))
    (zellij-send--slash-cache-store (zellij-send--slash-cache-key) alist
                                    (zellij-send--slash-cache-fingerprint))))

(defun zellij-send--slash-cache-drop ()
  "カレントバッファのディレクトリの一覧と全体用の一覧を、メモリからもディスクからも捨てる。
`C-u' で取り直すときに呼ぶ。全体用も捨てないと、取り直さずに全体用から作ってしまう。"
  (dolist (key (list (zellij-send--slash-cache-key) zellij-send--slash-global-key))
    (let ((file (zellij-send--slash-cache-file key)))
      (remhash key zellij-send--slash-cache-table)
      (when (and file (file-exists-p file))
        (with-demoted-errors "zellij-send: %S"
          (delete-file file))))))

(defvar zellij-send--slash-arg-cache-table (make-hash-table :test 'equal)
  "引数の候補メニューのキャッシュ。
キーは (ディレクトリ コマンド ここまでの引数)、値は ((候補 . 説明) ...)。
`/plugin install' のように候補が数百あるものを毎回集め直さないため。
**打ち切った（一部の）一覧は入れない**。`C-u' で捨てる。")

(defun zellij-send--slash-arg-cache-key (name args open)
  "NAME・ARGS（OPEN は末尾が書きかけか）の引数候補キャッシュのキーを返す。"
  (list (zellij-send--slash-cache-key) name (string-trim (or args "")) (and open t)))

(defun zellij-send--slash-arg-cached (name args open)
  "NAME・ARGS の引数候補を覚えていれば返す。無ければ nil。"
  (gethash (zellij-send--slash-arg-cache-key name args open)
           zellij-send--slash-arg-cache-table))

(defun zellij-send--slash-arg-cache-put (name args open entries)
  "NAME・ARGS の引数候補として ENTRIES を覚える。"
  (when entries
    (puthash (zellij-send--slash-arg-cache-key name args open) entries
             zellij-send--slash-arg-cache-table)))

(defun zellij-send--slash-arg-cache-clear ()
  "カレントバッファのディレクトリぶんの引数候補キャッシュを捨てる。
`maphash' の最中に消すと動作が保証されないので、キーを集めてから消す。"
  (let ((dir (zellij-send--slash-cache-key))
        (keys nil))
    (maphash (lambda (k _v) (when (equal (car k) dir) (push k keys)))
             zellij-send--slash-arg-cache-table)
    (dolist (k keys) (remhash k zellij-send--slash-arg-cache-table))))

(defun zellij-send--slash-msg (op format-string &rest args)
  "OP が先読み（`zellij-send-op-silent'）でなければ `message' する。
先読みは黙って走らせる。"
  (unless (and op (zellij-send-op-silent op))
    (apply #'message format-string args)))

;;;; ペインとのやりとり

(defun zellij-send--slash-clear-input (op callback)
  "OP のペインの入力欄を Ctrl+U で空に戻してから CALLBACK を呼ぶ。
打ちかけの印（`:typed'）も下ろす。OP が生きていなければ何もしない。"
  (zellij-send--op-keys op '(21)
                        (lambda (exit)
                          (zellij-send--op-put op :typed nil)
                          (funcall callback (zerop exit)))))

(defun zellij-send--slash-wait (op pred callback &optional tries)
  "OP のペインの画面が PRED を満たすまで待ち、その画面を CALLBACK に渡す。
待てなかったら nil を渡す。画面は毎回 `dump-screen' で取る——黒板バッファは
ユーザーが編集中だと更新が止まる（`buffer-modified-p'）ので当てにできない。"
  (let ((tries (or tries 0)))
    (zellij-send--op-dump
     op
     (lambda (screen)
       (cond
        ((and screen (funcall pred screen)) (funcall callback screen))
        ((>= tries 12) (funcall callback nil))
        (t (zellij-send--op-later op zellij-send-slash-settle-delay
                                  #'zellij-send--slash-wait
                                  op pred callback (1+ tries))))))))

;;;; メニューの取得（↓ で送りながら読む）

;; コマンド一覧と引数の候補は**同じ仕組み**で集める（2026-09-06 実測）。
;; 出る場所（入力枠のすぐ上）もスクロールの癖（カーソルが最下段に着いてから
;; 窓が 1 件ずつ動く・末尾で先頭へ折り返す）も同じで、違うのは行の形と、
;; メニューを開くために打つ文字列だけ。その差は SPEC の plist に閉じ込める:
;;
;;   :input      メニューを開くために入力欄へ打つ文字列（"/" や "/config "）
;;   :expect     集めている間、入力欄がこの文字列のままであること
;;   :parse      画面から ((値 . 説明) ...) を読む関数
;;   :max-rounds ↓ を送る回数の上限
;;   :sort       名前順に並べ替えるか（コマンド一覧だけ）
;;   :label      進捗メッセージに出す名前

(defun zellij-send--slash-command-spec ()
  "コマンド一覧を集めるための SPEC を返す。"
  (list :input "/" :expect "/"
        :parse #'zellij-send--slash-menu-entries
        :max-rounds zellij-send-slash-max-rounds
        :sort t
        :label "スラッシュコマンド"))

(defun zellij-send--slash-arg-spec (text)
  "引数の候補を集めるための SPEC を返す。TEXT はメニューを開く入力文字列。"
  (list :input text :expect (string-trim-right text)
        :parse #'zellij-send--slash-arg-entries
        :max-rounds zellij-send-slash-arg-max-rounds
        :sort nil
        :label "引数の候補"))

(defun zellij-send--slash-collect (buf callback &optional silent)
  "BUF のセッションのスラッシュコマンド一覧を集めて CALLBACK に渡す。
CALLBACK に渡す結果は次のどれか:

  (:ok (:entries ENTRIES :truncated TRUNCATED))  ENTRIES は空のこともある
  (:failed REASON)    入力欄が空でない・打てなかった
  (:aborted REASON)   ペインを操作された・別の操作が走っていた

TRUNCATED が non-nil の一覧は回数を使い切って打ち切ったもので、
キャッシュしてはいけない（以後ずっと欠けたまま出る）。
SILENT が non-nil なら進捗を知らせない（先読み）。

集めている間は BUF の操作（`zellij-send-op'）として排他を取る。
`zellij-send-abort' で止めたときは CALLBACK を呼ばない。"
  (let ((op (zellij-send--op-begin buf 'slash-collect :silent silent)))
    (if (null op)
        (funcall callback (list :aborted (zellij-send--op-busy-message buf)))
      (zellij-send--slash-collect-1
       op (lambda (result)
            (zellij-send--op-end op)
            (funcall callback result))))))

(defun zellij-send--slash-collect-1 (op done)
  "`zellij-send--slash-collect' の本体。結果を DONE に渡す。"
  (zellij-send--slash-wait
   op #'zellij-send--slash-idle-p
   (lambda (screen)
     (if (null screen)
         (progn (zellij-send--slash-msg
                 op "ペインの入力欄が空ではありません。先にペインを片付けてください")
                (funcall done (list :failed "ペインの入力欄が空ではありません")))
       (let ((spec (zellij-send--slash-command-spec))
             (finish (lambda (result)
                       (funcall done
                                (if result
                                    (list :ok result)
                                  (list :aborted "ペインが操作されたので取得を中止しました"))))))
         (zellij-send--op-write-chars
          op (plist-get spec :input)
          (lambda (ok)
            (if (not ok)
                (funcall done (list :failed "入力欄に打てませんでした"))
              (zellij-send--slash-wait
               op (plist-get spec :parse)
               (lambda (menu)
                 (if (null menu)
                     (zellij-send--slash-gather-finish op spec nil nil finish)
                   (zellij-send--slash-scroll
                    op spec nil 0 0 nil nil finish))))))))))))

(defun zellij-send--slash-scroll (op spec found rounds dry pinned last callback)
  "SPEC のメニューを ↓ で送りながら集め、集め終わったら CALLBACK に渡す。
FOUND は見つかった順の alist、ROUNDS は送った回数、DRY は画面が
進まなかった連続回数、PINNED はカーソルが最下段に着いているか、
LAST は前回見えていた値のリスト。

守るべき点が 2 つある:

- 送る ↓ の回数は**毎回、見えている件数から決める**。説明の折り返しで
  1 画面の件数が変わるので、一定量を飛ばすと静かに取りこぼす
- **画面が前回と同じ間は ↓ を送らない**。描画が追いついていないだけの
  画面を基準に次を送ると、実際の位置より先へ飛んで 1 件落ちる

一覧は最後まで行くと先頭へ折り返す。折り返した回は新顔が出ないので
DRY が伸びて止まる。**折り返しをまたぐ回だけは窓が飛ぶので最後の数件を
取りこぼす**（実測で末尾の `/verify' が落ちた）。その分は
`zellij-send--slash-tail' が ↑ の折り返しで拾う。"
  (cond
   ;; 回数を使い切った。集めた分は「一部」として返す（キャッシュには入れない）
   ((> rounds (plist-get spec :max-rounds))
    (zellij-send--slash-gather-finish op spec found t callback))
   (t
    (zellij-send--op-dump
     op
     (lambda (screen)
       (let* ((entries (and screen (funcall (plist-get spec :parse) screen)))
              (names (mapcar #'car entries))
              (new (seq-remove (lambda (e) (assoc (car e) found)) entries))
              (found (append found new))
              (stalled (equal names last))
              ;; 新顔が出ない＝一周した。画面が動かない＝描画待ちかキーが
              ;; 効いていない。どちらも「これ以上は取れない」側に数える
              (dry (if (or stalled (null new)) (1+ dry) 0))
              (visible (length entries)))
         (cond
          ;; 入力欄が変わった＝ユーザーがターミナル側で打ち始めた。
          ;; ここで Ctrl+U を送ると相手の入力を消すので、片付けずに手を引く
          ((and screen (not (equal (zellij-send--slash-input-text screen)
                                   (plist-get spec :expect))))
           (zellij-send--slash-msg op "ペインが操作されたので取得を中止しました")
           ;; 中途半端な一覧を覚えさせない。失敗として返す
           (funcall callback nil))
          ;; メニューが消えた（＝読み違えた）か、3 回続けて進まない
          ((or (null entries) (>= dry 3))
           (zellij-send--slash-tail op spec found names callback))
          (stalled
           ;; 描画待ち。送らずにもう一度読む
           (zellij-send--op-later op zellij-send-slash-settle-delay
                                  #'zellij-send--slash-scroll
                                  op spec found (1+ rounds) dry pinned names
                                  callback))
          (t
           (when (zerop (mod rounds 8))
             (zellij-send--slash-msg op "%sを取得中… %d 件"
                                     (plist-get spec :label) (length found)))
           (zellij-send--op-keys
            op
            ;; カーソルが最下段に着くまでは「見えている件数」、着いてからは
            ;; 「見えている件数 - 1」。後者なら 1 件重なりを残して窓が進む
            (apply #'append
                   (make-list (max 1 (if pinned (1- visible) visible))
                              '(27 91 66)))
            (lambda (exit)
              (if (not (zerop exit))
                  (zellij-send--slash-tail op spec found names callback)
                (zellij-send--op-later op zellij-send-slash-settle-delay
                                       #'zellij-send--slash-scroll
                                       op spec found (1+ rounds) dry t names
                                       callback))))))))))))

(defun zellij-send--slash-tail (op spec found last callback)
  "一覧の末尾を拾ってから `zellij-send--slash-gather-finish' へ渡す。
LAST は直前に見えていた値のリスト。

メニューを開き直して先頭に戻り、そこから **↑ を 1 回**送る。一覧は先頭で
折り返すので、これで最後の 1 画面がそのまま出る（2026-07-29 実測）。
↓ で送る本編は折り返しをまたぐ回に窓が飛ぶため、末尾の数件がここでしか
取れない。"
  (zellij-send--slash-clear-input
   op
   (lambda (_ok)
     (zellij-send--op-write-chars
      op (plist-get spec :input)
      (lambda (ok)
        (if (not ok)
            (zellij-send--slash-gather-finish op spec found nil callback)
          (zellij-send--slash-wait
           op (plist-get spec :parse)
           (lambda (screen)
             (zellij-send--slash-tail-up op spec found last screen
                                         callback)))))))))

(defun zellij-send--slash-tail-up (op spec found last screen callback)
  "先頭に戻った SCREEN から ↑ を 1 回送り、折り返した末尾の画面を読む。"
  (if (null screen)
      (zellij-send--slash-gather-finish op spec found nil callback)
    (let ((top (mapcar #'car (funcall (plist-get spec :parse) screen))))
      (zellij-send--op-keys
       op '(27 91 65)
       (lambda (exit)
         (if (not (zerop exit))
             (zellij-send--slash-gather-finish op spec found nil callback)
           (zellij-send--slash-wait
            op
            (lambda (s)
              (let ((names (mapcar #'car (funcall (plist-get spec :parse) s))))
                ;; ↑ が効いた（＝画面が動いた）ことを確かめてから読む
                (and names (not (equal names top)) (not (equal names last)))))
            (lambda (s)
              (let* ((entries (and s (funcall (plist-get spec :parse) s)))
                     (new (seq-remove (lambda (e) (assoc (car e) found)) entries)))
                (zellij-send--slash-gather-finish
                 op spec (append found new) nil callback))))))))))

(defun zellij-send--slash-gather-finish (op spec found truncated callback)
  "入力欄を片付けてから、集めた FOUND を CALLBACK に渡す。
CALLBACK に渡すのは plist (:entries ENTRIES :truncated TRUNCATED)。
TRUNCATED が non-nil なら回数を使い切って打ち切った一覧。"
  (zellij-send--slash-clear-input
   op
   (lambda (_ok)
     (funcall callback
              (list :entries (if (plist-get spec :sort)
                                 (sort (copy-sequence found)
                                       (lambda (a b) (string< (car a) (car b))))
                               found)
                    :truncated truncated)))))

;;;; 引数を読む（ゴーストのヒントと、カーソルで選ぶ候補メニュー）

;; `/name ' まで打ったときにペインが返すものは 2 通りある（2026-09-06 実測、
;; Claude Code v2.1.263）。**同じ調査を繰り返さないこと。**
;;
;; (1) ゴーストの引数ヒント（入力欄の中に薄く出る）
;;
;;       ❯ /effort  [low|medium|high|xhigh|max|ultracode|auto]
;;       ❯ /add-dir  <path>
;;
;; (2) 候補メニュー（コマンド一覧と同じ場所・同じ操作感。カーソルで選ぶ形）
;;
;;         autoScroll=                true | false      ← /config
;;         enable          Enable an installed plugin   ← /plugin
;;         cost-optimize                                ← /claude-api（説明なし）
;;         Documents/     directory                     ← /add-dir ~/Doc
;;
;; - 出るのはどちらか片方。ヒントが出るコマンドにメニューは出ない
;; - **ヒントは引数が空のときだけ出る**（`/name ' の空白が 1 つだけの状態）。
;;   `/plugin enable ' のような深い段では出ないので、そこでは読みに行かない
;; - **候補は入れ子になる**。`/plugin ' → `enable' → `/plugin enable ' →
;;   プラグイン名、`/config ' → `autoScroll=' → `/config autoScroll=' →
;;   `autoScroll=true'。だから 1 段で終わりにせず、選ぶたびに聞き直す
;; - 候補は**トークン全体**で返る（`autoScroll=' の次は `autoScroll=true'）。
;;   足すのではなく置き換えること（`zellij-send--slash-arg-append'）
;; - メニューのスクロールはコマンド一覧と同じ。ただし `/plugin install' は
;;   候補が数百あるので `zellij-send-slash-arg-max-rounds' で打ち切る
;; - `<path>` のヒントはペインに聞かず Emacs 側で補完する。ペインの
;;   ディレクトリ候補は途中まで打たないと出てこないため
;;
;; 2026-10-19 実測（Claude Code v2.1.303）: `/effort ' のヒントが入れ子になった
;; （`/effort  [low|medium|high|xhigh|max|auto|ultracode [on|off]]'）。
;; `zellij-send--slash-hint-values' は `|' で切るので、`ultracode' が落ちて
;; `ultracode' の引数の `off' が候補に混ざる。（→ 同日、括弧の外の `|' でだけ切るよう直した）`/config ' `/plugin ' の候補メニューと
;; `/add-dir  <path>' は 2026-09-06 と同じ形だった（test/fixtures/slash-arg-*.txt）。

(defun zellij-send--slash-probe-arg (buf name args open callback)
  "NAME の引数 ARGS の続きをペインに聞いて CALLBACK に渡す。
CALLBACK に渡す結果は次のどれか:

  (:ok nil)                               これ以上の引数は無い
  (:ok (:hint HINT))                      ゴーストの引数ヒント（引数が空のときだけ）
  (:ok (:values ENTRIES :truncated BOOL)) カーソルで選ぶ候補メニュー
  (:aborted REASON)                       ペインを操作されたなどで取得を中止した

「中止」を「引数なし」（`:ok nil'）と取り違えると、引数を付けずにそのまま
送ってしまう。2026-10-19 までは中止を `(:abort t)'、引数なしを nil で返していた。
読み終えたら入力欄は空に戻す。聞いている間は BUF の操作として排他を取る。"
  (let ((cached (and (buffer-live-p buf)
                     (with-current-buffer buf
                       (zellij-send--slash-arg-cached name args open)))))
    (cond
     ((not (buffer-live-p buf))
      (funcall callback (list :aborted "黒板がありません")))
     (cached (funcall callback (list :ok (list :values cached))))
     (t
      (let ((op (zellij-send--op-begin buf 'slash-arg)))
        (if (null op)
            (funcall callback (list :aborted (zellij-send--op-busy-message buf)))
          (let ((done (lambda (result)
                        (zellij-send--op-end op)
                        (funcall callback result))))
            ;; 打つ前に入力欄が空であることを確かめる。ユーザーがターミナル側で
            ;; 書きかけたテキストの後ろに打ち足すと、その入力を壊したうえに
            ;; 画面も読み違える（実機で踏んだ）
            (zellij-send--slash-wait
             op #'zellij-send--slash-idle-p
             (lambda (idle)
               (if (null idle)
                   (progn
                     (zellij-send--slash-msg
                      op "ペインの入力欄が空ではありません。先にペインを片付けてください")
                     (funcall done (list :aborted "ペインの入力欄が空ではありません")))
                 (zellij-send--slash-probe-write op name args open done)))))))))))

(defun zellij-send--slash-probe-write (op name args open callback)
  "NAME の引数 ARGS の続きを聞くための文字列を入力欄に打ち、画面を読む。"
  (let ((text (zellij-send--slash-probe-text name args open)))
    (zellij-send--op-write-chars
     op text
     (lambda (ok)
       (if (not ok)
           ;; 打てなかったのは「引数なし」ではない
           (funcall callback (list :aborted "入力欄に打てませんでした"))
         ;; ヒントは本文と同じ描画で出る。取りこぼさないよう一拍置く
         (zellij-send--op-later
          op zellij-send-slash-settle-delay
          (lambda ()
            (zellij-send--slash-wait
             op
             (lambda (s) (let ((it (zellij-send--slash-input-text s)))
                           (and it (string-prefix-p name it))))
             (lambda (screen)
               (zellij-send--slash-probe-read
                op name args open screen callback))))))))))

(defun zellij-send--slash-probe-read (op name args open screen callback)
  "SCREEN からヒントか候補メニューを読み、CALLBACK に渡す。
メニューが出ていたら ↓ を送りながら全件集める。"
  (let* ((empty (string-empty-p (string-trim (or args ""))))
         (hint (and screen empty (zellij-send--slash-arg-hint screen name)))
         (entries (and screen (null hint) (zellij-send--slash-arg-entries screen))))
    (cond
     ;; 打った文字が入力欄に出てこなかった。ペインの状態が分からないので
     ;; 「引数なし」とは読まずに中止する
     ((null screen)
      (zellij-send--slash-clear-input
       op (lambda (_ok) (funcall callback (list :aborted "入力欄が読めませんでした")))))
     (hint (zellij-send--slash-clear-input
            op (lambda (_ok) (funcall callback (list :ok (list :hint hint))))))
     (entries
      (zellij-send--slash-scroll
       op (zellij-send--slash-arg-spec
           (zellij-send--slash-probe-text name args open))
       nil 0 0 nil nil
       (lambda (result)
         (if (null result)
             (funcall callback (list :aborted "ペインが操作されたので取得を中止しました"))
           (let ((values (plist-get result :entries))
                 (truncated (plist-get result :truncated)))
             (when (and values (not truncated))
               (zellij-send--slash-arg-cache-put name args open values))
             (funcall callback (list :ok (list :values values
                                               :truncated truncated))))))))
     (t (zellij-send--slash-clear-input
         op (lambda (_ok) (funcall callback (list :ok nil))))))))

;;;; 入口

(defconst zellij-send--slash-arg-max-depth 5
  "引数を何段まで聞き直すか。
`/plugin enable NAME' のように候補は入れ子になるので繰り返し聞くが、
画面を読み違えて延々と聞き続けないための歯止め。")

(defun zellij-send--slash-table (alist)
  "ALIST（(値 . 説明)）を completing-read の補完表にする。
説明は注釈で出し、並びは渡された順のまま（メニューの順に意味がある）。"
  (lambda (str pred action)
    (if (eq action 'metadata)
        `(metadata
          (annotation-function
           . ,(lambda (cand)
                (let ((desc (cdr (assoc cand alist))))
                  (when desc
                    (concat "  "
                            (truncate-string-to-width desc 70 nil nil "…"))))))
          (display-sort-function . identity))
      (complete-with-action action alist str pred))))

(defun zellij-send--slash-read (alist)
  "ALIST（(名前 . 説明)）から completing-read で 1 つ選ばせる。
`/' を初期入力にしておくので、続けて英字を打つと絞り込める。
一覧に無いコマンドも打てるように require-match しない。"
  (completing-read "スラッシュコマンド: " (zellij-send--slash-table alist)
                   nil nil "/"))

(defun zellij-send--slash-read-hint (name hint)
  "ゴーストのヒント HINT に従って NAME の引数をミニバッファで尋ねる。
パスを求めるヒントは Emacs 側でパス補完し、`a|b|c' の形は候補にする。"
  (let ((kind (zellij-send--slash-hint-kind hint))
        (values (zellij-send--slash-hint-values hint)))
    (cond
     ((eq kind 'directory)
      (expand-file-name (read-directory-name (format "%s のディレクトリ: " name))))
     ((eq kind 'file)
      (expand-file-name (read-file-name (format "%s のファイル: " name))))
     (values
      (completing-read (format "%s の引数 [%s]（空で省略）: " name hint)
                       values nil nil))
     (t (read-string (format "%s の引数 [%s]（空で省略）: " name hint))))))

(defun zellij-send--slash-read-value (name info)
  "候補メニュー INFO から 1 つ選ばせる。空で確定したら nil を返す。
返すのは (値 . 一覧にあったか)。一覧に無い値は**絞り込みの打ちかけ**として
扱い、次にそれを打った状態で候補を出し直す——メニューは実測 12 件で
頭打ちなので、数文字打って絞るのが唯一の手段になる。"
  (let* ((entries (plist-get info :values))
         (value (string-trim
                 (completing-read
                  (format "%s の引数%s（空で省略・数文字打つと絞り込み）: " name
                          (if (plist-get info :truncated) "（候補は一部）" ""))
                  (zellij-send--slash-table entries) nil nil))))
    (unless (string-empty-p value)
      (cons value (and (assoc value entries) t)))))

(defun zellij-send--slash-submit (buf name args)
  "NAME と ARGS を組み立ててペインへ送る。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((text (string-trim (concat name " " (or args "")))))
        (zellij-send--send zellij-send--session text
                           (lambda (ok)
                             (when ok (message "送信しました: %s" text))))))))

(defun zellij-send--slash-run (buf name args open depth info)
  "NAME の引数を INFO に従って尋ね、決まったら送る。
ARGS はここまでに決まった引数文字列、OPEN は末尾のトークンが書きかけか、
DEPTH は何段目か。候補は入れ子になる（`/plugin' → `enable' → プラグイン名）
ので、1 つ選ぶたびに次の段を聞き直す。

INFO は `zellij-send--slash-probe-arg' の結果。

タイマーから呼ばれるので、BUF をカレントにしてから尋ねる（`<path>' の
補完が BUF の `default-directory' から始まるように）。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((ok (eq (car info) :ok))
            (info (cadr info)))
        (cond
         ((not ok)
          ;; 理由（入力欄が空でない・ペインを操作された など）を添える。
          ;; 添えないと、直前に出た理由をこの文が上書きして、何が起きたか分からない
          (message "引数の候補を取得できませんでした（%s）。ペインの状態を確認してください"
                   (or info "理由不明")))
         ((plist-get info :hint)
          (let ((arg (zellij-send--slash-read-hint name (plist-get info :hint))))
            (zellij-send--slash-submit
             buf name (string-trim (concat args " " (or arg ""))))))
         ((plist-get info :values)
          (let ((choice (zellij-send--slash-read-value name info)))
            (if (null choice)
                (zellij-send--slash-submit buf name args)
              (let* ((value (car choice))
                     (listed (cdr choice))
                     ;; 一覧から選んだ値は、それ自体が書きかけ（`autoScroll=' の
                     ;; ような）でなければ 1 トークンぶんの確定。一覧に無い値は
                     ;; 絞り込みの打ちかけとみなして、次はそれを打った状態で聞く
                     (next-open (if listed (zellij-send--slash-arg-open-p value) t))
                     (next (zellij-send--slash-arg-append args value open)))
                (if (>= depth zellij-send--slash-arg-max-depth)
                    (zellij-send--slash-submit buf name next)
                  (message "%s %s の続きを確認中…" name next)
                  (zellij-send--slash-probe-arg
                   buf name next next-open
                   (lambda (result)
                     ;; sentinel の中でミニバッファを開かない（C-g が効かなくなる）。
                     ;; 操作はもう終わっている（ここから先はミニバッファで聞くだけ）
                     (run-at-time 0 nil #'zellij-send--slash-run
                                  buf name next next-open (1+ depth) result))))))))
         (t (zellij-send--slash-submit buf name args)))))))

(defun zellij-send--slash-choose (buf &optional alist)
  "BUF のキャッシュ（ALIST があればそれ）から選ばせ、引数を尋ねてから送る。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((name (string-trim (zellij-send--slash-read
                                (or alist (zellij-send--slash-cached))))))
        (unless (string-empty-p name)
          (unless (string-prefix-p "/" name)
            (setq name (concat "/" name)))
          (message "%s の引数を確認中…" name)
          (zellij-send--slash-probe-arg
           buf name "" nil
           (lambda (result)
             ;; sentinel の中でミニバッファを開かない（C-g が効かなくなる）
             (run-at-time 0 nil #'zellij-send--slash-run
                          buf name "" nil 1 result))))))))

(defun zellij-send-slash-command (&optional refresh)
  "Claude Code のスラッシュコマンドを選んで送る。
コマンド一覧はペインの補完メニューから読み取り、作業ディレクトリごとに覚える
（`zellij-send-slash-prefetch' が non-nil なら黒板バッファを開いた時点で
先読みしてあるので、たいてい待ち時間は無い）。
REFRESH（`\\[universal-argument]'）を付けるとコマンド一覧と引数の候補を
取り直す。一覧はディスクにも保存してあり（`zellij-send-slash-cache-directory'）、
Emacs を再起動してもそのまま使う。REFRESH はその保存も捨てる。

コマンドを選ぶと引数も尋ねる。`/effort' のようにヒント（`[low|medium|…]'）
が出るものは候補から選び、`<path>' はディレクトリ補完で選ぶ。`/config' や
`/plugin' のようにペイン側でカーソルで選ぶ候補メニューが出るものは、
その候補を集めてミニバッファで選ばせる（`/plugin enable NAME' のように
入れ子になる場合は、選ぶたびに次の段を聞く）。

一覧の取得も引数の確認もペインの入力欄を実際に打って行うので、入力欄が
空でないときは何もしない。`/model' のように送信後に対話画面が出る
コマンドは、そのままキー透過モード（\\[zellij-send-keys-mode]）で操作する。

一覧の読み取りは Claude Code の補完メニュー専用。他のコマンドでは入力欄に
`/' を打ち込んで壊す危険があるので何もしない——そちらのスラッシュコマンドは
本文として送るか（C-c C-c）、キー透過モードで直接打つ。"
  (interactive "P")
  (zellij-send--assert-session)
  (zellij-send--assert-capability 'slash-completion)
  (zellij-send--op-assert-free)
  (when refresh
    ;; ディスクに保存した一覧も捨てる。取り直しに失敗しても古い一覧が
    ;; 次回の起動で復活しないように
    (zellij-send--slash-cache-drop)
    (zellij-send--slash-arg-cache-clear))
  (let ((buf (current-buffer)))
    (if (and (zellij-send--slash-cached) (not refresh))
        (zellij-send--slash-choose buf)
      (message "スラッシュコマンド一覧を取得中…（初回のみ数秒かかります）")
      (zellij-send--slash-collect
       buf
       (lambda (result)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (let* ((value (and (eq (car result) :ok) (cadr result)))
                    (alist (plist-get value :entries))
                    (truncated (plist-get value :truncated)))
               (if (null alist)
                   (message "コマンド一覧を取得できませんでした。ペインの状態を確認してください")
                 ;; 打ち切った一覧は今回だけ使い、キャッシュせず次回は取り直す
                 (unless truncated
                   (zellij-send--slash-cache-put alist))
                 (message "スラッシュコマンド %d 件%s" (length alist)
                          (if truncated "（一部）" ""))
                 (run-at-time 0 nil #'zellij-send--slash-choose buf alist))))))))))

;;;; 先読み

(defun zellij-send--slash-prefetch-maybe ()
  "一覧をまだ持っていなければ、少し待ってから黙って取りに行く。
`zellij-send--subscribe-start' から呼ばれる（＝ペインに繋がった時点）。
初回の `zellij-send-slash-command' を待たせないための先読み。"
  (when (and zellij-send-slash-prefetch
             zellij-send--session
             (zellij-send--confirmed-capable-p 'slash-completion)
             (null (zellij-send--slash-cached))
             (not (zellij-send--op-current)))
    ;; ここはまだ何も打たない（始める前に条件を確かめ直す）ので op の外でよい
    (run-at-time zellij-send-slash-prefetch-delay nil
                 #'zellij-send--slash-prefetch-run (current-buffer) 1)))


(add-hook 'zellij-send--pane-connected-hook #'zellij-send--slash-prefetch-maybe)

(defun zellij-send--slash-prefetch-run (buf try)
  "BUF の一覧を黙って取りに行く。TRY は何回目か。
取れなければ少し置いてやり直す——起動直後の claude は信頼確認などで
入力欄が空でないことがあり、その間は取得を諦めるため。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and zellij-send-slash-prefetch
                 zellij-send--session
                 zellij-send--pane-id
                 (zellij-send--confirmed-capable-p 'slash-completion)
                 (null (zellij-send--slash-cached))
                 (not (zellij-send--op-current))
                 (<= try zellij-send-slash-prefetch-retries))
        (zellij-send--slash-collect
         buf
         (lambda (result)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (let* ((value (and (eq (car result) :ok) (cadr result)))
                      (alist (plist-get value :entries)))
                 ;; 打ち切った一覧は覚えない。取り直しても同じなので再試行もしない
                 (cond
                  ((plist-get value :truncated) nil)
                  (alist (zellij-send--slash-cache-put alist))
                  (t
                   ;; 再試行までの間は何も打たないので op の外で待つ。
                   ;; `zellij-send-abort' で止めた取得はここに来ない（再試行しない）
                   (run-at-time zellij-send-slash-prefetch-delay nil
                                #'zellij-send--slash-prefetch-run
                                buf (1+ try))))))))
         t)))))

;;; AskUserQuestion（選択肢プロンプト）への回答

(defcustom zellij-send-askq-auto 'keys
  "質問を検出した時点で何を自動で開くか。

- `keys'      … キー透過モード（`zellij-send-keys-mode'）に入る。
                黒板には生画面がそのまま映っているので、説明文や事例を
                読みながら数字キー・↑↓・RET で答えられる（既定）
- `minibuffer' … ミニバッファの `completing-read' で選ばせる（旧挙動）。
                ラベルしか出ないので、説明が要る質問には向かない
- nil         … 何もしない

nil でも `zellij-send-answer-question'（C-c C-q）で手動で開ける。
互換のため t は `minibuffer' として扱う。"
  :type '(choice (const :tag "キー透過モード" keys)
                 (const :tag "ミニバッファ" minibuffer)
                 (const :tag "自動で開かない" nil))
  :group 'zellij-send)

(defun zellij-send--askq-auto-method ()
  "`zellij-send-askq-auto' を `keys' / `minibuffer' / nil に正規化する。
旧設定の t は `minibuffer'（旧挙動）に読み替える。"
  (pcase zellij-send-askq-auto
    ('keys 'keys)
    ('nil nil)
    (_ 'minibuffer)))

(defcustom zellij-send-askq-settle-delay 0.8
  "キーを送ってから画面を読み直すまでの待ち時間（秒）。"
  :type 'number
  :group 'zellij-send)

(defvar-local zellij-send--askq-active nil
  "直前の画面更新で質問が出ていたか。自動起動の立ち上がり検出に使う。")

(defcustom zellij-send-askq-max-rounds 12
  "1 回の回答フローで処理する質問の上限。
これを超えたら打ち切る。署名（画面の内容）が毎回変わる形で空回りしても
必ず止まるようにするための最後の歯止め——実際、自由入力の欄に数字キーを
打ち込み続けて画面が毎回変わる不具合を踏んだことがある。"
  :type 'integer
  :group 'zellij-send)

(defun zellij-send--askq-read (prompt opts &optional multi)
  "OPTS から選ばせて、選ばれた選択肢のリストを返す。
MULTI が non-nil なら複数選べる。"
  (let* ((cands (mapcar #'zellij-send--askq-candidate opts))
         (table (cl-mapcar #'cons cands opts)))
    (if multi
        (delq nil (mapcar (lambda (c) (cdr (assoc c table)))
                          (completing-read-multiple prompt cands nil t)))
      (let ((c (completing-read prompt cands nil t)))
        (list (cdr (assoc c table)))))))

;;;; 送信の下請け

(defun zellij-send--askq-send-keys (op seq &optional callback)
  "OP のペインへ SEQ（バイト列のリスト）を順に送る。
最後に CALLBACK へ成功 t / 失敗 nil を渡す。OP が死んだら途中でやめる。"
  (if (null seq)
      (when callback (funcall callback t))
    (zellij-send--op-keys
     op (car seq)
     (lambda (exit)
       (if (zerop exit)
           (zellij-send--askq-send-keys op (cdr seq) callback)
         (message "キー送信に失敗しました (exit: %d)" exit)
         (when callback (funcall callback nil)))))))

(defun zellij-send--askq-screen (op callback)
  "OP のペインの画面を `dump-screen' で取り、CALLBACK に渡す。
取れなければ nil を渡す。CALLBACK は OP の黒板をカレントにして呼ばれる。

回答フローは黒板の中身（`buffer-string'）を読まない。黒板には下書き・
transcript・クリア後の空が入っていることがあり、それを画面だと思って
解析すると、質問を見失うか別の選択肢を押す。スラッシュコマンド
（`zellij-send--slash-wait'）と同じく、毎回ペインから取り直す。
CALLBACK は sentinel の中で走るので、ミニバッファを開くなら
`zellij-send--op-later' で抜けてからにすること。"
  (zellij-send--op-dump op callback))

(defun zellij-send--askq-focus (op num callback &optional tries)
  "OP の画面でカーソル (❯) を選択肢 NUM に合わせてから CALLBACK を呼ぶ。
移動量を一度に計算せず 1 つずつ動かして毎回確認する。説明文の折り返しで
行数がずれても壊れないようにするため（QR メニューで踏んだ失敗と同じ轍）。
画面は毎回ペインから取り直す（`zellij-send--askq-screen'）。
CALLBACK には成功 t / 失敗 nil を渡す。"
  (let ((tries (or tries 0)))
    (if (> tries 12)
        (progn (message "カーソルを選択肢 %d に合わせられませんでした" num)
               (funcall callback nil))
      (zellij-send--askq-screen
       op
       (lambda (screen)
         (let* ((q (zellij-send--askq-parse screen))
                (opts (plist-get q :options))
                (cur (seq-position opts nil (lambda (o _) (plist-get o :focused))))
                (target (seq-position opts nil
                                      (lambda (o _) (= (plist-get o :num) num)))))
           (cond
            ((or (null cur) (null target))
             (message "画面から選択肢を読み取れませんでした")
             (funcall callback nil))
            ((= cur target) (funcall callback t))
            (t
             (zellij-send--askq-send-keys
              op (list (if (< cur target) '(27 91 66) '(27 91 65)))
              (lambda (ok)
                (if (not ok)
                    (funcall callback nil)
                  (zellij-send--op-later op zellij-send-askq-settle-delay
                                         #'zellij-send--askq-focus
                                         op num callback (1+ tries)))))))))))))

;;;; 回答フロー

(defun zellij-send--askq-finish (op)
  "回答フロー OP を終える。"
  (zellij-send--op-end op))

(defun zellij-send--askq-after (op ok)
  "キー送信の後始末。OK なら画面が落ち着いてから次の質問を探す。"
  (if (not ok)
      (zellij-send--askq-finish op)
    (zellij-send--op-later op zellij-send-askq-settle-delay
                           #'zellij-send--askq-continue op)))

(defun zellij-send--askq-continue (op)
  "OP の画面をペインから取り直し、まだ質問があれば続けて答える。
取り直すのは、黒板に下書きがあると `buffer-string' が画面ではないため
（`zellij-send--askq-screen'）。続きの判断はミニバッファを開きうるので、
sentinel を `zellij-send--op-later' で抜けてから行う。"
  (zellij-send--askq-screen
   op
   (lambda (screen)
     (zellij-send--op-later op 0 #'zellij-send--askq-continue-1 op screen))))

(defun zellij-send--askq-continue-1 (op screen)
  "`zellij-send--askq-continue' の本体。SCREEN は取り直した画面（nil もある）。
同じ画面が続いた回数（`:repeat'）と直前の署名（`:signature'）は OP の状態に持つ。"
  (let ((q (zellij-send--askq-enrich (zellij-send--askq-parse screen)
                                     zellij-send--hook-questions))
        (signature (zellij-send--op-get op :signature)))
    (cond
     ((null screen)
      (zellij-send--askq-finish op)
      (message "画面を取得できませんでした。ペインを直接確認してください"))
     ((null q)
      (zellij-send--askq-finish op)
      (message "回答しました → [%s]" zellij-send--session))
     ;; 同じ画面が続くのは、キーが効いていないか読み違えている合図。
     ;; 黙って聞き続けるとミニバッファが無限に開くので必ず打ち切る
     ((and (equal signature (zellij-send--askq-signature q))
           (>= (zellij-send--op-get op :repeat) 2))
      (zellij-send--askq-finish op)
      (message "画面が変わりません。ペインを直接確認してください"))
     (t
      (if (equal signature (zellij-send--askq-signature q))
          (zellij-send--op-put op :repeat (1+ (zellij-send--op-get op :repeat)))
        (zellij-send--op-put op :signature (zellij-send--askq-signature q))
        (zellij-send--op-put op :repeat 0))
      (zellij-send--askq-answer op q)))))

(defun zellij-send--askq-answer (op q)
  "OP の質問 Q に対する回答を尋ねてキーを送る。
処理した質問の数（`:rounds'）は OP の状態に持つ。"
  (zellij-send--op-put op :rounds (1+ (or (zellij-send--op-get op :rounds) 0)))
  (if (> (zellij-send--op-get op :rounds) zellij-send-askq-max-rounds)
      (progn
        (zellij-send--askq-finish op)
        (message "質問を %d 回処理しても終わらないので打ち切りました。ペインを直接確認してください"
                 zellij-send-askq-max-rounds))
    (zellij-send--askq-dispatch op q)))

(defun zellij-send--askq-dispatch (op q)
  "Q の種類に応じた回答フローを呼ぶ。C-g で抜けたら OP を止める。"
  (condition-case _err
      (pcase (plist-get q :kind)
        ('review (zellij-send--askq-answer-review op q))
        (_ (if (plist-get q :multi)
               (zellij-send--askq-answer-multi op q)
             (zellij-send--askq-answer-single op q))))
    (quit (zellij-send--op-abort
           (zellij-send-op-buffer op)
           "回答を中止しました（ペインは質問のままです。Esc は C-c C-k）"))))

(defun zellij-send--askq-answer-single (op q)
  "単一選択の質問 Q に答える。数字キー 1 つで確定し、次の質問へ自動で進む。"
  (let* ((opts (plist-get q :options))
         (opt (car (zellij-send--askq-read
                    (format "%s: " (plist-get q :question)) opts))))
    (if (zellij-send--askq-other-p opt)
        ;; 自由入力はカーソルを合わせると入力欄になる。paste して Enter で確定
        (let ((text (read-string "自由入力: ")))
          (zellij-send--askq-focus
           op (plist-get opt :num)
           (lambda (ok)
             (if (not ok)
                 (zellij-send--askq-finish op)
               (zellij-send--send
                zellij-send--session text
                (zellij-send--op-callback
                 op (lambda (ok2) (zellij-send--askq-after op ok2))))))))
      (zellij-send--askq-send-keys
       op (list (zellij-send--askq-digits opt))
       (lambda (ok) (zellij-send--askq-after op ok))))))

(defun zellij-send--askq-answer-multi (op q)
  "複数選択の質問 Q に答える。数字キーでトグルし、→ で確認画面へ進む。"
  (let* ((opts (plist-get q :options))
         (chosen (zellij-send--askq-read
                  (format "%s（複数可・カンマ区切り）: " (plist-get q :question))
                  opts t))
         (plain (seq-find (lambda (o) (not (plist-get o :box))) chosen)))
    (if plain
        ;; チェックボックスでない選択肢（Chat about this など）は単独で決定
        (zellij-send--askq-send-keys
         op (list (zellij-send--askq-digits plain))
         (lambda (ok) (zellij-send--askq-after op ok)))
      (let* ((other (seq-find #'zellij-send--askq-other-p chosen))
             (text (when other (read-string "自由入力: ")))
             (toggles (seq-filter
                       (lambda (o)
                         (and (plist-get o :box)
                              (not (eq (and (memq o chosen) t)
                                       (plist-get o :checked)))))
                       opts))
             (keys (mapcar #'zellij-send--askq-digits toggles)))
        (zellij-send--askq-send-keys
         op keys
         (lambda (ok)
           (cond
            ((not ok) (zellij-send--askq-finish op))
            (other
             (zellij-send--op-later op zellij-send-askq-settle-delay
                                    #'zellij-send--askq-fill-other op other text))
            (t (zellij-send--askq-submit-multi op nil)))))))))

(defun zellij-send--askq-fill-other (op other text)
  "複数選択の自由入力 OTHER に TEXT を書き込んでから確認画面へ進む。
数字キーでトグルしただけではラベルは Type something のままなので、
カーソルを合わせてから `paste' する（Enter は不要）。"
  (zellij-send--askq-focus
   op (plist-get other :num)
   (lambda (ok)
     (if (not ok)
         (zellij-send--askq-finish op)
       (zellij-send--zellij-async
        (append (list "--session" zellij-send--session "action" "paste")
                (zellij-send--pane-args)
                (list "--" text))
        (zellij-send--op-callback
         op (lambda (exit)
              (if (zerop exit)
                  (zellij-send--askq-submit-multi op t)
                (message "自由入力の送信に失敗しました (exit: %d)" exit)
                (zellij-send--askq-finish op)))))))))

(defun zellij-send--askq-submit-multi (op from-text)
  "複数選択の質問を確定して次のタブ（確認画面）へ進む。

FROM-TEXT が non-nil なら、カーソルは自由入力の欄にある。
**その状態では ←/→ はタブ移動ではなく入力欄内のカーソル移動になる**
（実機で踏んだ。→ を送っても質問画面から出られず、次の周回で数字キーが
入力欄に打ち込まれて `自由入力テスト4444…' になった）。
入力欄の直下は必ず `Submit' 行なので、↓ と Enter で確定する。
それ以外は → でタブを進める（どちらも実測で確認済み）。"
  (zellij-send--op-later
   op zellij-send-askq-settle-delay
   (lambda ()
     (zellij-send--askq-send-keys
      op (if from-text '((27 91 66) (13)) '((27 91 67)))
      (lambda (ok) (zellij-send--askq-after op ok))))))

(defun zellij-send--askq-answer-review (op q)
  "確認画面 Q で送信するかを尋ねる。"
  (let* ((opts (plist-get q :options))
         (submit (seq-find (lambda (o) (string-match-p "Submit" (plist-get o :label))) opts))
         (cancel (seq-find (lambda (o) (string-match-p "Cancel" (plist-get o :label))) opts))
         (opt (if (y-or-n-p "この内容で回答を送信しますか? ") submit cancel)))
    (if (null opt)
        (progn (message "確認画面の選択肢を読み取れませんでした")
               (zellij-send--askq-finish op))
      (zellij-send--askq-send-keys
       op (list (zellij-send--askq-digits opt))
       (lambda (ok) (zellij-send--askq-after op ok))))))

;;;; 入口と自動起動

(defun zellij-send-answer-question ()
  "画面に出ている AskUserQuestion に Emacs 側で答える。
選択肢をミニバッファで選ぶと、対応する数字キーをペインへ送る。
質問が複数ある場合は最後の確認画面まで続けて尋ねる。

画面の読み取りは Claude Code 専用。他のコマンドではキー透過モード
（\\[zellij-send-keys-mode]）を使う。"
  (interactive)
  (zellij-send--assert-session)
  (zellij-send--assert-capability 'askq)
  (zellij-send--op-assert-free)
  ;; 黒板ではなくペインの画面を読む。下書きを書いた黒板で C-c C-q を
  ;; 押しても、画面に出ている質問に答えられるように（`--askq-screen'）
  (let ((op (zellij-send--op-begin (current-buffer) 'askq)))
    (zellij-send--askq-screen
     op
     (lambda (screen)
       (zellij-send--op-later op 0 #'zellij-send--askq-start op screen)))))

(defun zellij-send--askq-start (op screen)
  "取り直した SCREEN に質問があれば、OP の回答フローを始める。
`zellij-send-answer-question' から sentinel を抜けた後に呼ばれる。"
  (let ((q (zellij-send--askq-enrich (zellij-send--askq-parse screen)
                                     zellij-send--hook-questions)))
    (cond
     ((null screen)
      (zellij-send--askq-finish op)
      (message "画面を取得できませんでした"))
     ((null q)
      (zellij-send--askq-finish op)
      (message "画面に選択肢プロンプトが見つかりません"))
     (t
      (zellij-send--op-put op :signature (zellij-send--askq-signature q))
      (zellij-send--op-put op :repeat 0)
      (zellij-send--op-put op :rounds 0)
      (zellij-send--askq-answer op q)))))

(defun zellij-send--askq-auto-open (buf)
  "BUF に質問が出たので回答 UI を開く。
`zellij-send--update-buffer' から `run-at-time' 経由で呼ばれる。
プロセスフィルタの中でミニバッファを開かないための遠回りなので、
ここを直接呼び出しに変えないこと。"
  (when (and (buffer-live-p buf)
             (not (minibufferp))
             (not (active-minibuffer-window)))
    (with-current-buffer buf
      (unless (zellij-send--op-current)
        ;; `--update-buffer' から 1 拍置いて来るので、その間に下書きが
        ;; 入っていることがある。バッファではなく受け取った画面で確かめる
        (when (zellij-send--askq-parse (zellij-send--last-screen))
          ;; 表示はするがウィンドウは選ばない（別バッファでの作業を邪魔しない）
          (display-buffer buf)
          (pcase (zellij-send--askq-auto-method)
            ('keys (zellij-send--askq-keys-enter))
            ('minibuffer (call-interactively #'zellij-send-answer-question))))))))

(defun zellij-send--askq-keys-enter ()
  "質問が出たのでキー透過モードに入る。カレントバッファで呼ぶ。
既に入っているなら何もしない（自動で入ったという印も付け替えない）。"
  (unless zellij-send-keys-mode
    (setq zellij-send--askq-keys-auto t)
    (zellij-send-keys-mode 1)
    (message "質問です。%s に移って数字 / ↑↓ / RET で答えてください（C-c C-t で解除）"
             (buffer-name))))

(defun zellij-send--askq-keys-exit ()
  "質問が消えたので、自動で入ったキー透過モードだけ抜ける。"
  (when (and zellij-send--askq-keys-auto zellij-send-keys-mode)
    (zellij-send-keys-mode -1))
  (setq zellij-send--askq-keys-auto nil))

(defun zellij-send--askq-maybe-auto (screen)
  "画面更新のたびに呼ばれ、SCREEN に質問が出た瞬間だけ回答 UI を開く。
SCREEN は書き込んだ画面の正規形（黒板の中身は表示形なので読まない）。
質問が消えたときは、自動で入ったキー透過モードを元に戻す。

`zellij-send--askq-parse' は Claude Code の AskUserQuestion の画面だけを
読むので、他のコマンド（codex など）のときは何もしない。そちらの選択肢は
キー透過モード（\\[zellij-send-keys-mode]）で操作する——あれは画面を
解釈しないのでどの TUI にも効く。"
  ;; 自動起動は数字キーの送信やキー透過モードへの切り替えを伴うので、
  ;; 推測ではなく**確定したコマンド**で判断する
  (let ((now (and (zellij-send--confirmed-capable-p 'askq)
                  (zellij-send--askq-parse screen) t)))
    (cond
     ((and now
           (not zellij-send--askq-active)
           (zellij-send--askq-auto-method)
           (not (zellij-send--op-current)))
      (run-at-time 0 nil #'zellij-send--askq-auto-open (current-buffer)))
     ((and (not now) zellij-send--askq-keys-auto)
      (zellij-send--askq-keys-exit)))
    (setq zellij-send--askq-active now)))

(provide 'zellij-send-claude)

;;; zellij-send-claude.el ends here
