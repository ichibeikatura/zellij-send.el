;;; zellij-send-parse-test.el --- 実機の画面（fixture）でパーサを確かめる -*- lexical-binding: t; -*-

;;; Commentary:

;; 実行方法（リポジトリのルートから）:
;;
;;   emacs -Q -batch -L . -l test/zellij-send-parse-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; 画面解析の中核は文字列を受けて構造を返す関数なので、実機で採った画面を
;; そのまま食わせれば回帰テストになる。パーサの失敗は「黙って何もしない」か
;; 「別の場所に打ち込む」なので、Claude Code が TUI を変えたときに気付く
;; 手段はここしかない。zellij も Claude Code も起動しない。
;;
;; fixture は test/fixtures/ にある（2026-10-19、Claude Code v2.1.303 /
;; codex-cli 0.160.0 / Antigravity CLI 1.4.2 / zellij 0.45.1、320 桁 × 498 行の
;; 背景セッション）。採り方は test/fixtures/capture.sh の先頭のコメント。
;; 先頭の `#fixture: ' で始まる注記行は**テスト側が読み込み時に落とす**
;; （パーサには注記の知識を持たせない）。中身は dump-screen が返したバイト列
;; そのままで、伏せたのは Remote Control の URL・メールアドレス・
;; 他のプロジェクトのセッション名だけ（いずれも同じ長さのダミー）。

;;; Code:

(require 'ert)
(require 'zellij-send)

(defconst zellij-send-parse-test--dir
  (expand-file-name "fixtures"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "fixture の置き場所。")

(defun zellij-send-parse-test--raw (name &optional ext)
  "fixture NAME（拡張子なし）の中身を、先頭の注記行を落として返す。
EXT は拡張子（既定は \".txt\"。`--ansi' で採ったものは \".ansi\"）。"
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat name (or ext ".txt")) zellij-send-parse-test--dir))
    (goto-char (point-min))
    (while (looking-at "#fixture: ")
      (forward-line 1))
    (buffer-substring-no-properties (point) (point-max))))

(defun zellij-send-parse-test--screen (name)
  "fixture NAME を、パーサが受け取るのと同じ形の画面にして返す。
dump-screen の生の出力を、本体が受信後に通す処理（正規形）にかける。"
  (zellij-send--normalize-screen (zellij-send-parse-test--raw name)))

(defmacro zellij-send-parse-test--with-command (command &rest body)
  "黒板のコマンドを COMMAND にした一時バッファで BODY を実行する。"
  (declare (indent 1))
  `(with-temp-buffer
     (setq-local zellij-send--command ,command)
     ,@body))

(defun zellij-send-parse-test--options (q key)
  "質問 Q の選択肢それぞれの KEY の値をリストで返す。"
  (mapcar (lambda (o) (plist-get o key)) (plist-get q :options)))

;;; 1. AskUserQuestion の解析

(ert-deftest zellij-send-parse-test-askq-single ()
  "単一選択。番号・ラベル・説明・カーソルを読む。"
  (let ((q (zellij-send--askq-parse (zellij-send-parse-test--screen "askq-single"))))
    (should (eq (plist-get q :kind) 'question))
    (should-not (plist-get q :multi))
    (should (equal (plist-get q :question) "好きな色はどれですか？"))
    (should (equal (zellij-send-parse-test--options q :num) '(1 2 3 4 5)))
    (should (equal (zellij-send-parse-test--options q :label)
                   '("青" "赤" "緑" "Type something." "Chat about this")))
    (should (equal (zellij-send-parse-test--options q :focused)
                   '(t nil nil nil nil)))
    (should (equal (plist-get (car (plist-get q :options)) :desc)
                   "空や海の色。落ち着いた、涼しげな印象です。"))))

(ert-deftest zellij-send-parse-test-askq-other ()
  "自由入力にカーソルが乗った画面。カーソルの位置だけが変わる。"
  (let ((q (zellij-send--askq-parse (zellij-send-parse-test--screen "askq-other"))))
    (should (eq (plist-get q :kind) 'question))
    (should (equal (zellij-send-parse-test--options q :focused)
                   '(nil nil nil t nil)))
    (should (zellij-send--askq-other-p (nth 3 (plist-get q :options))))))

(ert-deftest zellij-send-parse-test-askq-multi ()
  "複数選択。チェックボックスの有無とチェック状態を読む。"
  (let ((q (zellij-send--askq-parse (zellij-send-parse-test--screen "askq-multi"))))
    (should (eq (plist-get q :kind) 'question))
    (should (plist-get q :multi))
    (should (equal (plist-get q :question) "好きな果物はどれですか？（複数選択可）"))
    (should (equal (zellij-send-parse-test--options q :label)
                   '("りんご" "みかん" "いちご" "ぶどう" "Type something"
                     "Chat about this")))
    (should (equal (zellij-send-parse-test--options q :checked)
                   '(nil t nil nil nil nil)))
    ;; 罫線の下の Chat about this にはチェックボックスが無い
    (should (equal (zellij-send-parse-test--options q :box)
                   '(t t t t t nil)))))

(ert-deftest zellij-send-parse-test-askq-review ()
  "最終確認。**ヒント行が無い**ので、それを前提にした判定では読めない。"
  (let* ((screen (zellij-send-parse-test--screen "askq-review"))
         (q (zellij-send--askq-parse screen)))
    (should-not (string-match-p zellij-send-askq-hint-regexp screen))
    (should (eq (plist-get q :kind) 'review))
    (should (equal (zellij-send-parse-test--options q :label)
                   '("Submit answers" "Cancel")))
    (should (equal (zellij-send-parse-test--options q :focused) '(t nil)))))

(ert-deftest zellij-send-parse-test-askq-not-question ()
  "質問ではない画面（待機・作業中・信頼確認・スラッシュメニュー）を質問と読まない。"
  (dolist (name '("idle" "idle-after-turn" "working-spinner" "working-streaming"
                  "claude-trust" "slash-menu-top" "slash-arg-config"))
    (should-not (zellij-send--askq-parse (zellij-send-parse-test--screen name)))))

;;; 2. フックの原文で補う

(defconst zellij-send-parse-test--hook-questions
  '(((question . "好きな色はどれですか？")
     (header . "色")
     (multiSelect . nil)
     (options ((label . "青") (description . "空や海の色。落ち着いた、涼しげな印象です。長い説明の続き。"))
              ((label . "赤") (description . "炎や夕焼けの色。"))
              ((label . "緑") (description . "木々や草原の色。")))))
  "askq-single に対応する PreToolUse フックの questions（説明だけ長くしたもの）。")

(ert-deftest zellij-send-parse-test-askq-enrich ()
  "照合できたときだけ原文で置き換え、食い違えば画面の側をそのまま返す。"
  (let* ((q (zellij-send--askq-parse (zellij-send-parse-test--screen "askq-single")))
         (rich (zellij-send--askq-enrich q zellij-send-parse-test--hook-questions)))
    (should (equal (plist-get (car (plist-get rich :options)) :desc)
                   "空や海の色。落ち着いた、涼しげな印象です。長い説明の続き。"))
    ;; カーソルと付け足しの選択肢は画面のもの
    (should (plist-get (car (plist-get rich :options)) :focused))
    (should (= (length (plist-get rich :options)) 5)))
  ;; 別の質問（複数選択の画面）には当てない
  (let ((q (zellij-send--askq-parse (zellij-send-parse-test--screen "askq-multi"))))
    (should (equal (zellij-send--askq-enrich q zellij-send-parse-test--hook-questions)
                   q))))

;;; 3. スラッシュコマンドの補完メニュー

;; v2.1.303 は選択中の項目の行頭に `❯' を描く（`  ❯ /ndl  …'）。
;; 2026-10-19 にこの 4 本で見つけ、`zellij-send--slash-entry-regexp' を直した。

(ert-deftest zellij-send-parse-test-slash-menu-wrapped ()
  "説明が折り返しても、続き行を拾わずに件数が合う。"
  (should (equal (mapcar #'car (zellij-send--slash-menu-entries
                                (zellij-send-parse-test--screen "slash-menu-wrapped")))
                 '("/doctor" "/skill-doctor"))))

(ert-deftest zellij-send-parse-test-slash-menu-top ()
  "先頭（選択中の項目が一番上）。"
  (should (equal (mapcar #'car (zellij-send--slash-menu-entries
                                (zellij-send-parse-test--screen "slash-menu-top")))
                 '("/ndl" "/kdp-figure"))))

(ert-deftest zellij-send-parse-test-slash-menu-middle ()
  "中間（選択中の項目が真ん中）。"
  (should (equal (mapcar #'car (zellij-send--slash-menu-entries
                                (zellij-send-parse-test--screen "slash-menu-middle")))
                 '("/install-github-app" "/install-slack-app" "/keybindings"
                   "/list-agents" "/login"))))

(ert-deftest zellij-send-parse-test-slash-menu-tail ()
  "末尾（選択中の項目が一番下。入力枠のすぐ上）。"
  (should (equal (mapcar #'car (zellij-send--slash-menu-entries
                                (zellij-send-parse-test--screen "slash-menu-tail")))
                 '("/update-config" "/verify" "/workflow-authoring"))))

(ert-deftest zellij-send-parse-test-slash-menu-below-cursor ()
  "選択中の行より下の項目は、今の正規表現でも読める。
上の 4 本が失敗扱いの間も `zellij-send--slash-entry-regexp' を実画面で守るため。
`❯' を読めるようにした後も成り立つ（下の項目はどちらでも同じ）。"
  (should (equal (last (mapcar #'car (zellij-send--slash-menu-entries
                                      (zellij-send-parse-test--screen "slash-menu-middle")))
                       2)
                 '("/list-agents" "/login")))
  (let ((entries (zellij-send--slash-menu-entries
                  (zellij-send-parse-test--screen "slash-menu-wrapped"))))
    (should (equal (car (car (last entries))) "/skill-doctor"))
    (should (equal (cdr (car (last entries)))
                   "Show which loaded skills are unused and costing context"))))

(ert-deftest zellij-send-parse-test-slash-menu-none ()
  "メニューが出ていない画面からは拾わない。"
  (dolist (name '("idle" "idle-after-turn" "working-streaming" "askq-single"))
    (should-not (zellij-send--slash-menu-entries
                 (zellij-send-parse-test--screen name)))))

(ert-deftest zellij-send-parse-test-slash-input ()
  "入力欄の中身と、入力を受け付けられるか。"
  (should (equal (zellij-send--slash-input-text
                  (zellij-send-parse-test--screen "slash-menu-wrapped"))
                 "/doctor"))
  ;; プレースホルダは空とみなす
  (should (zellij-send--slash-idle-p (zellij-send-parse-test--screen "idle")))
  (should (zellij-send--slash-idle-p (zellij-send-parse-test--screen "idle-after-turn")))
  (should-not (zellij-send--slash-idle-p (zellij-send-parse-test--screen "slash-menu-top")))
  ;; 質問が出ている間は矢印がそちらに効くので、空でも受け付けない
  (should-not (zellij-send--slash-idle-p (zellij-send-parse-test--screen "askq-single"))))

(ert-deftest zellij-send-parse-test-slash-input-suggestion ()
  "ターン後の提案文（薄い字）は、`--ansi' で取って消せば空の入力欄と読む。"
  (let ((raw (zellij-send-parse-test--raw "idle-suggestion" ".ansi")))
    ;; 平文では本物の入力と見分けられない（これで常に「空ではない」になった）
    (should (equal (zellij-send--slash-input-text (zellij-send--normalize-screen raw))
                   "誤字直してPDF作り直して"))
    (should-not (zellij-send--slash-idle-p (zellij-send--normalize-screen raw)))
    (let ((screen (zellij-send--normalize-screen (zellij-send--blank-faint-input raw))))
      (should (equal (zellij-send--slash-input-text screen) ""))
      (should (zellij-send--slash-idle-p screen))
      ;; 入力欄より上の行は変えない
      (should (string-match-p "/clear to start fresh" screen))))
  ;; 薄くない文字が 1 つでもあれば本物の入力。薄いヒントが続いても消さない
  (dolist (line '("\e[m❯\u00a0\e[22m/effort\e[2m  [low|medium]"
                  ;; 拡張色の 2 は薄い字ではない
                  "\e[m❯\u00a0\e[38;5;2m本物の入力"
                  "\e[m❯\u00a0\e[2m提案\e[22mと本物"))
    (let ((raw (concat "本文\n" line "\n")))
      (should (equal (zellij-send--blank-faint-input raw) raw))))
  ;; 薄い字が 0 で戻っても、その後の文字が無ければ提案だけ
  (should (equal (zellij-send--blank-faint-input "上\n\e[m❯\u00a0\e[2m提案\e[0m\n下")
                 "上\n❯\n下"))
  ;; 入力欄が無い画面はそのまま
  (should (equal (zellij-send--blank-faint-input "\e[2m本文") "\e[2m本文")))

;;; 4. 引数の候補メニューとヒント

(ert-deftest zellij-send-parse-test-slash-arg-entries ()
  "候補メニューを読む。本文の行（`⏺' 始まりや箇条書き）は候補にしない。"
  (should (equal (zellij-send--slash-arg-entries
                  (zellij-send-parse-test--screen "slash-arg-config"))
                 '(("artifacts=" . "true | false")
                   ("autoCompact=" . "true | false")
                   ("autoConnectIde=" . "true | false")
                   ("autoScroll=" . "true | false"))))
  (should (equal (mapcar #'car (zellij-send--slash-arg-entries
                                (zellij-send-parse-test--screen "slash-arg-plugin")))
                 '("enable" "disable" "install" "uninstall")))
  ;; メニューの無い画面・コマンド一覧の画面からは拾わない
  (dolist (name '("idle-after-turn" "working-streaming" "slash-menu-top"
                  "slash-hint-effort"))
    (should-not (zellij-send--slash-arg-entries
                 (zellij-send-parse-test--screen name)))))

(ert-deftest zellij-send-parse-test-slash-arg-hint ()
  "ゴーストの引数ヒント。角括弧と山括弧の両方を読む。"
  (let ((effort (zellij-send--slash-arg-hint
                 (zellij-send-parse-test--screen "slash-hint-effort") "/effort"))
        (add-dir (zellij-send--slash-arg-hint
                  (zellij-send-parse-test--screen "slash-hint-add-dir") "/add-dir")))
    (should (equal effort "low|medium|high|xhigh|max|auto|ultracode [on|off]"))
    (should (equal add-dir "path"))
    (should (eq (zellij-send--slash-hint-kind add-dir) 'directory))
    (should (equal (zellij-send--slash-hint-values effort)
                   '("low" "medium" "high" "xhigh" "max" "auto" "ultracode")))
    ;; ヒントは名前が合うときだけ
    (should-not (zellij-send--slash-arg-hint
                 (zellij-send-parse-test--screen "slash-hint-effort") "/model"))
    ;; メニューが出るコマンドにはヒントが無い
    (should-not (zellij-send--slash-arg-hint
                 (zellij-send-parse-test--screen "slash-arg-config") "/config"))))

;;; 引数の確認を通しで（実画面を順に返す）

(defun zellij-send-parse-test--probe (screens)
  "SCREENS（fixture 名のリスト）を dump-screen の結果として順に返しながら、
`/effort' の引数を確かめる。最後の画面は何度でも返す。結果と打ったキーを返す。"
  (let ((queue screens) typed keys result)
    (with-temp-buffer
      (setq-local zellij-send--session "fixture00"
                  zellij-send--pane-id "terminal_1"
                  zellij-send--command "claude")
      (cl-letf (((symbol-function 'zellij-send--dump-screen-async)
                 (lambda (_session cb &rest _)
                   (funcall cb (zellij-send-parse-test--screen
                                (if (cdr queue) (pop queue) (car queue))))))
                ((symbol-function 'zellij-send--slash-write-chars)
                 (lambda (_session text cb)
                   (push text typed)
                   ;; 打った後の画面に進める
                   (when (cdr queue) (pop queue))
                   (funcall cb t)))
                ((symbol-function 'zellij-send--send-keys)
                 (lambda (_session bytes &optional cb) (push bytes keys)
                   (when cb (funcall cb 0))))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args) (apply fn args))))
        (zellij-send--slash-probe-arg (current-buffer) "/effort" "" nil
                                      (lambda (r) (setq result r)))
        (list result (nreverse typed) (nreverse keys)
              (zellij-send--op-current))))))

(ert-deftest zellij-send-parse-test-probe-effort ()
  "待機中のペインに `/effort ' を打ち、v2.1.303 のゴーストのヒントを読んで片付ける。"
  (pcase-let ((`(,result ,typed ,keys ,op)
               (zellij-send-parse-test--probe '("idle" "slash-hint-effort"))))
    (should (equal result
                   '(:ok (:hint "low|medium|high|xhigh|max|auto|ultracode [on|off]"))))
    (should (equal typed '("/effort ")))
    ;; 読み終えたら Ctrl+U で入力欄を空に戻し、操作も終えている
    (should (equal keys '((21))))
    (should-not op)))

(ert-deftest zellij-send-parse-test-probe-refuses-busy-input ()
  "入力欄が空でない（質問が出ている）ペインには打たずに断る。"
  (pcase-let ((`(,result ,typed ,keys ,op)
               (zellij-send-parse-test--probe '("askq-single"))))
    (should (eq (car result) :aborted))
    (should-not typed)
    (should-not keys)
    (should-not op)))

;;; 5. 選択肢プロンプトの検出（エージェントごとの記号）

(ert-deftest zellij-send-parse-test-detect-prompt ()
  "claude の ❯・codex の ›・agy の > を、それぞれのバッファでだけ拾う。"
  (dolist (case '(("askq-single" "claude" t)
                  ("askq-review" "claude" t)
                  ("codex-select" "codex" t)
                  ("agy-permission" "agy" t)
                  ;; agy の `> 1.' は claude のバッファでは markdown 引用と区別できない
                  ("agy-permission" "claude" nil)
                  ;; 番号の無い信頼確認は選択肢として拾わない（数字を送ると本文になる）
                  ("claude-trust" "claude" nil)
                  ("agy-trust" "agy" nil)
                  ("idle" "claude" nil)
                  ("agy-idle" "agy" nil)
                  ("working-streaming" "claude" nil)
                  ("slash-menu-top" "claude" nil)))
    (zellij-send-parse-test--with-command (nth 1 case)
      (should (eq (and (zellij-send--detect-prompt
                        (zellij-send-parse-test--screen (nth 0 case)))
                       t)
                  (nth 2 case))))))

(ert-deftest zellij-send-parse-test-detect-prompt-quote ()
  "本文の markdown 引用 `> 1. りんご' は claude では拾わず、agy では拾う。"
  (let ((screen (replace-regexp-in-string
                 "^⏺ コマンドを実行しました。"
                 "> 1. りんご\n> 2. みかん\n⏺ コマンドを実行しました。"
                 (zellij-send-parse-test--screen "idle-after-turn"))))
    (zellij-send-parse-test--with-command "claude"
      (should-not (zellij-send--detect-prompt screen)))
    (zellij-send-parse-test--with-command "agy"
      (should (zellij-send--detect-prompt screen)))))

;;; 状態（作業中・選択待ち・待機）を実機の画面で

(ert-deftest zellij-send-parse-test-session-status ()
  "画面だけで判定したときの状態。フックは無く、画面は 1 分前から変わっていない。"
  (dolist (case '(("idle" "claude" idle)
                  ("idle-after-turn" "claude" idle)
                  ("working-spinner" "claude" working)
                  ("working-thinking" "claude" working)
                  ;; 本文を流している間はスピナー行が出ない。画面変化で拾う
                  ("working-streaming" "claude" idle)
                  ("askq-single" "claude" prompt)
                  ("askq-review" "claude" prompt)
                  ("claude-trust" "claude" idle)
                  ("codex-select" "codex" prompt)
                  ("agy-permission" "agy" prompt)
                  ("agy-idle" "agy" idle)))
    (zellij-send-parse-test--with-command (nth 1 case)
      (setq-local zellij-send--session "fixture00")
      (setq-local zellij-send--last-content
                  (zellij-send-parse-test--screen (nth 0 case)))
      (setq-local zellij-send--last-change-time (- (float-time) 60))
      (should (eq (plist-get (zellij-send-session-state (current-buffer)) :status)
                  (nth 2 case)))))
  ;; 本文を流している最中でも、画面が今まさに変わっていれば作業中
  (zellij-send-parse-test--with-command "claude"
    (setq-local zellij-send--last-content
                (zellij-send-parse-test--screen "working-streaming"))
    (setq-local zellij-send--last-change-time (float-time))
    (should (eq (plist-get (zellij-send-session-state (current-buffer)) :status)
                'working))))

;;; 6. 起動コマンドからエージェント名

(ert-deftest zellij-send-parse-test-command-name ()
  "list-panes の COMMAND 列の実際の形から名前を取る。"
  (should (equal (zellij-send--command-name "node /opt/homebrew/bin/codex") "codex"))
  (should (equal (zellij-send--command-name "claude --remote-control zjs-fixture00")
                 "claude"))
  (should (equal (zellij-send--command-name "agy") "agy"))
  ;; インタプリタでなければ引数を見ない
  (should-not (equal (zellij-send--command-name "cat /tmp/claude") "claude")))

;;; 7. セッション一覧

(ert-deftest zellij-send-parse-test-parse-sessions ()
  "ANSI 付きの実際の出力から名前だけを取る。0 件の案内文を名前にしない。"
  (should (equal (zellij-send--parse-sessions
                  (zellij-send-parse-test--raw "list-sessions"))
                 '("project01" "sample-proj00" "zjs-fixture00" "zjs-fixture01"
                   "zjs-fixture02")))
  (should-not (zellij-send--parse-sessions
               (zellij-send-parse-test--raw "list-sessions-empty"))))

;;; 8・9. ペインの選択と終了の判定

(ert-deftest zellij-send-parse-test-terminal-panes ()
  "plugin ペインを除き、COMMAND と EXITED を読む。"
  (should (equal (zellij-send--parse-terminal-panes
                  (zellij-send-parse-test--raw "list-panes"))
                 '(("terminal_1" "claude --remote-control zjs-fixture00" nil))))
  (should (equal (zellij-send--parse-terminal-panes
                  (zellij-send-parse-test--raw "list-panes-exited"))
                 '(("terminal_1" "claude --remote-control zjs-fixture00" t)))))

(ert-deftest zellij-send-parse-test-pick-pane ()
  "生きているペインを優先し、全部終了していても同じ順で選ぶ。"
  (let ((zellij-send-default-command "claude"))
    (should (equal (zellij-send--pick-pane
                    (zellij-send--parse-terminal-panes
                     (zellij-send-parse-test--raw "list-panes")))
                   "terminal_1"))
    ;; /exit 後の終了済みペインしか無くても、最後の画面を読めるよう選ぶ
    (should (equal (zellij-send--pick-pane
                    (zellij-send--parse-terminal-panes
                     (zellij-send-parse-test--raw "list-panes-exited")))
                   "terminal_1"))
    ;; 終了済みの claude より、生きている shell を先に選ぶ
    (should (equal (zellij-send--pick-pane
                    (cons '("terminal_0" "/bin/zsh" nil)
                          (zellij-send--parse-terminal-panes
                           (zellij-send-parse-test--raw "list-panes-exited"))))
                   "terminal_0"))))

(ert-deftest zellij-send-parse-test-parse-pane-exited ()
  "動いていれば nil、終了なら t、判定できなければ :unknown。**絶対に t を推測しない**。"
  (should-not (zellij-send--parse-pane-exited
               (zellij-send-parse-test--raw "list-panes") "terminal_1"))
  (should (eq (zellij-send--parse-pane-exited
               (zellij-send-parse-test--raw "list-panes-exited") "terminal_1")
              t))
  (dolist (case (list (cons (zellij-send-parse-test--raw "list-panes") "terminal_9")
                      (cons (zellij-send-parse-test--raw "list-sessions") "terminal_1")
                      (cons (zellij-send-parse-test--raw "list-sessions-empty") "terminal_1")
                      (cons "" "terminal_1")))
    (should (eq (zellij-send--parse-pane-exited (car case) (cdr case)) :unknown))))

;;; 縮んだセッションの広げ直し（大きさとクライアント数）

(ert-deftest zellij-send-parse-test-terminal-extent ()
  "端末ペインの右端と下端の最大。見えない zellij:link プラグインのはみ出しを数えない。"
  (should (equal (zellij-send--parse-terminal-extent
                  (zellij-send-parse-test--raw "list-panes"))
                 '(320 . 499)))
  ;; 100 桁 × 30 行の端末で attach → detach した後の背景セッション
  (should (equal (zellij-send--parse-terminal-extent
                  (zellij-send-parse-test--raw "list-panes-shrunk"))
                 '(100 . 29)))
  (dolist (raw (list (zellij-send-parse-test--raw "list-sessions")
                     (zellij-send-parse-test--raw "list-clients")
                     "" nil))
    (should-not (zellij-send--parse-terminal-extent raw))))

(ert-deftest zellij-send-parse-test-client-count ()
  "クライアントが居なくても見出し行は出る。見出しが無いものは 0 件と読まない。"
  (should (eql (zellij-send--parse-client-count
                (zellij-send-parse-test--raw "list-clients"))
               1))
  (should (eql (zellij-send--parse-client-count
                (zellij-send-parse-test--raw "list-clients-empty"))
               0))
  (dolist (raw (list (zellij-send-parse-test--raw "list-panes")
                     "Session 'nosuch' not found. The following sessions are active:\nt2\n"
                     "" nil))
    (should-not (zellij-send--parse-client-count raw))))

;;; ペインの幅で入った改行のつなぎ直し

(defun zellij-send-parse-test--joined (name)
  "fixture NAME をつなぎ直した行のリストを返す。"
  (split-string (zellij-send--join-wrapped-lines (zellij-send-parse-test--raw name))
                "\n"))

(ert-deftest zellij-send-parse-test-join-wrapped-diff ()
  "差分の続きの行を、行番号の欄と付け直した記号を除いてつなぐ。
英文は単語の途中で切れ、切れ目の空白は前の行の末尾で削られている。"
  (let ((lines (zellij-send-parse-test--joined "diff-wrapped")))
    ;; 日本語: 全角が入らず 1 桁余った分は空白にしない
    (should (member (concat "      416 -`[New]` で作る背景セッションは zellij の既定では 50 桁 × 48 行と狭く、"
                            "Claude Code はペイン幅で改行を入れて出力するので本文が細切れになります。"
                            "zellij-send は作成時に一瞬だけ attach して広げます。既存のセッションは "
                            "`M-x zellij-send-resize-session` で後から広げられます。ターミナルから "
                            "`zellij attach` すると、zellij の仕様でそのクライアントの大きさまで縮みます。")
                    lines))
    ;; 英文: 313 桁目の空白が削られて消えた行は空白を戻し、単語の途中で切れた行は詰める
    (should (seq-find (lambda (l) (string-match-p "\\`      416 -A .* Attaching from a terminal shrinks" l))
                      lines))
    (should (seq-find (lambda (l) (string-match-p "\\`      416 \\+A .* Attaching from a terminal shrinks" l))
                      lines))
    ;; 続きの行は残らない。行番号のある行と罫線はそのまま
    (should-not (seq-find (lambda (l) (string-match-p "\\`          [-+]" l)) lines))
    (should (member "      417" lines))
    (should (member "  ⎿ \u00a0Added 1 line, removed 1 line" lines))))

(ert-deftest zellij-send-parse-test-join-wrapped-prose ()
  "日本語の段落は 320 桁いっぱいで切れた行だけつなぎ、選択肢や罫線には触れない。"
  (let* ((raw (zellij-send-parse-test--raw "askq-multi"))
         (lines (zellij-send-parse-test--joined "askq-multi")))
    ;; 2 行に分かれていた段落が 1 行になる
    (should (seq-find (lambda (l) (string-match-p "からなのか、人の気配が少ないからなのか" l)) lines))
    (should-not (member "  か、人の気配が少ないからなのか、理由はよく知らない。ただ、夏の朝よりも世界が一枚薄く、遠くまで透けて見えるような気がする。" lines))
    ;; 桁いっぱいでない行（300 桁）は次の段落とつながない
    (should (= (length (split-string raw "\n"))
               (+ (length lines) 12)))
    ;; 選択肢の解析に使う部分は変わらない
    (should (equal (zellij-send--askq-parse (string-join lines "\n"))
                   (zellij-send--askq-parse raw)))))

;;; 10. 編集の差分

(ert-deftest zellij-send-parse-test-diff-hunk ()
  "前後の共通行が文脈行になり、行番号は断片の中での番号になる。"
  (let ((zellij-send-transcript-max-block-lines nil))
    (should (equal (zellij-send--diff-hunk "a\nb\nc\nd\n" "a\nB\nB2\nc\nd\n")
                   "@@ -1,4 +1,5 @@\n a\n-b\n+B\n+B2\n c\n d\n"))
    ;; 先頭だけ・末尾だけが変わっても文脈行の数が合う
    (should (equal (zellij-send--diff-hunk "x\ny" "X\ny")
                   "@@ -1,2 +1,2 @@\n-x\n+X\n y\n"))
    (should (equal (zellij-send--diff-hunk "x\ny" "x\nY")
                   "@@ -1,2 +1,2 @@\n x\n-y\n+Y\n"))))

;;; 表示の設定は解析に効かない

(ert-deftest zellij-send-parse-test-max-blank-lines-independent ()
  "`zellij-send-max-blank-lines' を 0 にしても 10 にしても、解析の結果が変わらない。"
  (dolist (name '("askq-single" "askq-multi" "askq-review" "slash-menu-top"
                  "slash-menu-tail" "slash-arg-config" "slash-hint-effort" "idle"))
    (let ((results
           (mapcar (lambda (n)
                     (let ((zellij-send-max-blank-lines n))
                       (let ((screen (zellij-send-parse-test--screen name)))
                         (list (zellij-send--askq-parse screen)
                               (zellij-send--slash-menu-entries screen)
                               (zellij-send--slash-arg-entries screen)
                               (zellij-send--slash-input-text screen)))))
                   '(0 2 10 nil))))
      (should (equal (nth 0 results) (nth 1 results)))
      (should (equal (nth 0 results) (nth 2 results)))
      (should (equal (nth 0 results) (nth 3 results))))))

;;; subscribe の 1 イベント

(ert-deftest zellij-send-parse-test-subscribe-event ()
  "実際の subscribe のイベントから画面を作る。右詰めの空白は残さない。"
  (with-temp-buffer
    (setq-local zellij-send--session "fixture00")
    ;; 黒板の書き換えは別の話なので止めておく（下書きがある状態）
    (insert "下書き")
    (set-buffer-modified-p t)
    (zellij-send--subscribe-handle-line
     (with-temp-buffer
       (insert-file-contents
        (expand-file-name "subscribe-event.jsonl" zellij-send-parse-test--dir))
       (buffer-string)))
    (should zellij-send--last-change-time)
    (should (string-match-p "冬の朝" zellij-send--last-content))
    (should-not (string-match-p " $" zellij-send--last-content))
    ;; 黒板には触らない
    (should (equal (buffer-string) "下書き"))))

(provide 'zellij-send-parse-test)

;;; zellij-send-parse-test.el ends here
