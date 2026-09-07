;;; zellij-send-test.el --- zellij-send のテスト -*- lexical-binding: t; -*-

;;; Commentary:

;; 実行方法（リポジトリのルートから）:
;;
;;   emacs -Q -batch -L . -l ert -l test/zellij-send-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; zellij を必要としない純粋な関数だけを対象にする。

;;; Code:

(require 'ert)
(require 'zellij-send)

;;; zellij-send--strip-ansi

(ert-deftest zellij-send-test-strip-ansi-csi ()
  "CSI シーケンスが除去される。"
  (should (equal (zellij-send--strip-ansi "\033[32;1mzellij-send\033[m")
                 "zellij-send"))
  (should (equal (zellij-send--strip-ansi "a\033[2Kb\033[?25lc") "abc")))

(ert-deftest zellij-send-test-strip-ansi-osc ()
  "OSC は BEL 終端でも ST 終端でも残骸を残さない。
旧実装は `ESC ]' の 2 文字だけを食い、`0;title' とベル文字が残っていた。"
  (should (equal (zellij-send--strip-ansi "前\033]0;window title\a後") "前後"))
  (should (equal (zellij-send--strip-ansi "前\033]0;window title\033\\後") "前後"))
  ;; 連続する OSC が貪欲マッチで間の本文ごと消えないこと
  (should (equal (zellij-send--strip-ansi "\033]0;A\aX\033]0;B\aY") "XY")))

(ert-deftest zellij-send-test-strip-ansi-two-char ()
  "ESC ( B のような 2 文字エスケープが除去される。"
  (should (equal (zellij-send--strip-ansi "\033(Bhello") "hello"))
  (should (equal (zellij-send--strip-ansi "a\033=b\033>c") "abc")))

(ert-deftest zellij-send-test-strip-ansi-mixed ()
  "OSC・CSI・2 文字エスケープが混在しても本文だけが残る。"
  (should (equal (zellij-send--strip-ansi
                  "\033]0;title\a\033[1;34m日本語\033[0m\033(B です")
                 "日本語 です")))

(ert-deftest zellij-send-test-strip-ansi-plain ()
  "エスケープを含まないテキストは一切変化しない。"
  (let ((plain "セッション一覧を取得しました [Created 2m 7s ago]"))
    (should (equal (zellij-send--strip-ansi plain) plain)))
  (should (equal (zellij-send--strip-ansi "") "")))

;;; zellij-send--process-dump

(ert-deftest zellij-send-test-process-dump-trailing-spaces ()
  "subscribe の viewport が付ける行末パディングを削る。"
  (should (equal (zellij-send--process-dump
                  (concat "日本語の行" (make-string 300 ?\s) "\n"
                          (make-string 320 ?\s) "\n"
                          "次の行" (make-string 10 ?\s)))
                 "日本語の行\n\n次の行")))

(ert-deftest zellij-send-test-process-dump-trailing-blank-lines ()
  "画面下端の連続空行（パディングだけの行）をまとめて落とす。"
  (should (equal (zellij-send--process-dump
                  (concat "本文\n" (make-string 320 ?\s) "\n   \n\n"))
                 "本文")))

(ert-deftest zellij-send-test-process-dump-keeps-inner-blanks-and-indent ()
  "本文中の空行と行頭のインデントは保つ。"
  (should (equal (zellij-send--process-dump "  上\t \n\n  下  ")
                 "  上\n\n  下")))

(ert-deftest zellij-send-test-process-dump-strips-ansi-then-spaces ()
  "ANSI を除去した結果の行末空白も削る（除去順の確認）。"
  (should (equal (zellij-send--process-dump "本文\033[0m   \n")
                 "本文")))

;;; zellij-send--parse-sessions

(ert-deftest zellij-send-test-parse-sessions ()
  "`NAME [Created ...]' の行だけを採用し、案内文と EXITED を除外する。"
  (should (equal (zellij-send--parse-sessions
                  "\033[32;1mfoo\033[m [Created \033[35;1m2m 7s\033[m ago] (current)\nbar [Created 1h ago]\n")
                 '("foo" "bar")))
  ;; セッション 0 件の案内文からセッション名 "No" を作らない
  (should (equal (zellij-send--parse-sessions "No active zellij sessions found.\n")
                 nil))
  ;; EXITED セッションは除外する
  (should (equal (zellij-send--parse-sessions
                  "alive [Created 1m ago]\ndead [Created 5m ago] (EXITED - attach to resurrect)\n")
                 '("alive"))))

;;; zellij-send--parse-pane-exited

(defconst zellij-send-test--list-panes-all
  (concat
   "TAB_ID  TAB_POS  TAB_NAME  PANE_ID  TYPE  TITLE  COMMAND  CWD  FOCUSED  FLOATING  EXITED  X  Y  ROWS  COLS\n"
   "0  0  Tab #1  plugin_0  plugin  (.) - zellij:link  zellij:link  -  false  false  false  13  13  25  25\n"
   "0  0  Tab #1  terminal_1  terminal  claude  claude  -  true  false  true  0  1  48  50\n"
   "0  0  Tab #1  terminal_2  terminal  claude  caffeinate -i -t 300  /Users/x  true  false  false  0  1  47  209\n")
  "実機（zellij 0.44.3）の `action list-panes --all' 出力を写したもの。")

(ert-deftest zellij-send-test-parse-pane-exited ()
  "EXITED 列を読む。列位置はヘッダから求めるので、COMMAND に空白が入っても崩れない。"
  (should (eq (zellij-send--parse-pane-exited
               zellij-send-test--list-panes-all "terminal_1")
              t))
  (should (eq (zellij-send--parse-pane-exited
               zellij-send-test--list-panes-all "terminal_2")
              nil))
  ;; 居ないペインは :unknown（「終了した」と誤判定しない）
  (should (eq (zellij-send--parse-pane-exited
               zellij-send-test--list-panes-all "terminal_9")
              :unknown)))

(ert-deftest zellij-send-test-parse-pane-exited-broken-input ()
  "壊れた入力で t を返さない。t は「消してよい」の合図なので誤検出が最も危険。"
  (should (eq (zellij-send--parse-pane-exited nil "terminal_1") :unknown))
  (should (eq (zellij-send--parse-pane-exited "" "terminal_1") :unknown))
  ;; EXITED 列を持たない旧来の表（list-panes を --all なしで叩いた場合）
  (should (eq (zellij-send--parse-pane-exited
               "PANE_ID  TYPE  TITLE\nterminal_1  terminal  claude\n" "terminal_1")
              :unknown)))

;;; zellij-send--askq-parse
;;
;; 素材は 2026-07-29 に実機（Claude Code v2.1.220 / zellij 0.44.3、320 桁の
;; 背景セッション）で dump-screen した画面をそのまま貼ったもの。
;; 想像で書いた画面ではないので、ここが通れば実機でも読める。

(defconst zellij-send-test--askq-single "\
⏺ I'll ask both questions at once. No files will be touched.
────────────────────────────────────────
←  ☐ 好きな色  ☐ 好きな果物  ✔ Submit  →

好きな色はどれですか？

❯ 1. 青
     空や海の色。落ち着いた印象。
  2. 赤
     情熱的で目を引く色。
  3. 緑
     自然や植物の色。目に優しい。
  4. Type something.
────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
")

(defconst zellij-send-test--askq-multi "\
────────────────────────────────────────
←  ☒ 好きな色  ☒ 好きな果物  ✔ Submit  →

好きな果物はどれですか（複数選択可）？

❯ 1. [ ] りんご
  定番。シャキシャキした食感。
  2. [✔] みかん
  冬の定番。手で剥ける手軽さ。
  3. [ ] ぶどう
  甘みが強く種なしも人気。
  4. [✔] いちご
  春の味覚。デザートの主役。
  5. [ ] Type something
     Submit
────────────────────────────────────────
  6. Chat about this

Enter to select · Tab/Arrow keys to navigate · ctrl+g to edit in Vim · Esc to cancel
")

;; 確認画面にはヒント行が無い（実機の通し確認で判明。ヒント行だけを条件に
;; すると、ここで回答フローが止まる）。素材は実機のダンプそのまま。
(defconst zellij-send-test--askq-review "\
────────────────────────────────────────
←  ☒ 色  ☒ 果物  ✔ Submit  →

Review your answers

 ● テスト用のダミー質問です。好きな色はどれですか？
   → 青
 ● テスト用のダミー質問です。好きな果物を選んでください（複数可）。
   → りんご, ぶどう

Ready to submit your answers?

❯ 1. Submit answers
  2. Cancel


")

(defconst zellij-send-test--askq-lone "\
❯ もう一度テストです。
────────────────────────────────────────
 ☐ 朝か夜か

朝と夜、どちらが好きですか？

❯ 1. 朝
     早起きして静かな時間に作業するのが好き。
  2. 夜
     夜更けに集中して作業するのが好き。
  3. Type something.
────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
")

(ert-deftest zellij-send-test-askq-parse-none ()
  "質問が出ていない画面では nil を返す。"
  (should-not (zellij-send--askq-parse ""))
  (should-not (zellij-send--askq-parse nil))
  (should-not (zellij-send--askq-parse "❯ 1. 青\n  2. 赤\n通常のプロンプト\n")))

(ert-deftest zellij-send-test-askq-parse-single ()
  "単一選択の質問を読み取る。カーソル・説明・自由入力まで拾う。"
  (let* ((q (zellij-send--askq-parse zellij-send-test--askq-single))
         (opts (plist-get q :options)))
    (should (eq (plist-get q :kind) 'question))
    (should-not (plist-get q :multi))
    (should (equal (plist-get q :question) "好きな色はどれですか？"))
    (should (= (length opts) 5))
    (should (equal (mapcar (lambda (o) (plist-get o :label)) opts)
                   '("青" "赤" "緑" "Type something." "Chat about this")))
    (should (equal (plist-get (nth 0 opts) :desc) "空や海の色。落ち着いた印象。"))
    (should (plist-get (nth 0 opts) :focused))
    (should-not (plist-get (nth 1 opts) :focused))
    (should (zellij-send--askq-other-p (nth 3 opts)))
    (should (equal (zellij-send--askq-digits (nth 3 opts)) '(?4)))))

(ert-deftest zellij-send-test-askq-parse-multi ()
  "複数選択はチェック状態まで読み取る。トグルの要否がこれで決まる。"
  (let* ((q (zellij-send--askq-parse zellij-send-test--askq-multi))
         (opts (plist-get q :options)))
    (should (plist-get q :multi))
    (should (equal (plist-get q :question) "好きな果物はどれですか（複数選択可）？"))
    (should (equal (mapcar (lambda (o) (plist-get o :label)) opts)
                   '("りんご" "みかん" "ぶどう" "いちご" "Type something"
                     "Chat about this")))
    (should (equal (mapcar (lambda (o) (plist-get o :checked)) opts)
                   '(nil t nil t nil nil)))
    ;; 罫線の下にある Chat about this にはチェックボックスが無い
    (should (plist-get (nth 4 opts) :box))
    (should-not (plist-get (nth 5 opts) :box))
    (should (zellij-send--askq-other-p (nth 4 opts)))))

(ert-deftest zellij-send-test-askq-parse-review ()
  "確認画面はヒント行が無くても review として読み取れる。"
  (let* ((q (zellij-send--askq-parse zellij-send-test--askq-review))
         (opts (plist-get q :options)))
    (should (eq (plist-get q :kind) 'review))
    (should-not (string-match-p zellij-send-askq-hint-regexp
                                zellij-send-test--askq-review))
    (should (equal (mapcar (lambda (o) (plist-get o :label)) opts)
                   '("Submit answers" "Cancel")))))

(ert-deftest zellij-send-test-askq-parse-question-wins ()
  "確認画面より下に新しい質問が出ていれば、そちらを読む。
古い確認画面の残骸に引きずられて、答え済みの画面をもう一度出さないこと。"
  (let ((q (zellij-send--askq-parse
            (concat zellij-send-test--askq-review "\n"
                    zellij-send-test--askq-single))))
    (should (eq (plist-get q :kind) 'question))
    (should (equal (plist-get q :question) "好きな色はどれですか？"))))

(ert-deftest zellij-send-test-askq-parse-lone ()
  "質問が 1 つだけならタブ行が簡略化され、ヒント行も別文言になる。
ヒントを `Tab/Arrow' で見分けると、この画面を取りこぼす。"
  (let ((q (zellij-send--askq-parse zellij-send-test--askq-lone)))
    (should q)
    (should (equal (plist-get q :question) "朝と夜、どちらが好きですか？"))
    (should (= (length (plist-get q :options)) 4))))

(ert-deftest zellij-send-test-askq-signature ()
  "署名は画面が変わったかどうかを見分ける（無限ループの歯止め）。"
  (let ((a (zellij-send--askq-parse zellij-send-test--askq-single))
        (b (zellij-send--askq-parse zellij-send-test--askq-multi)))
    (should (equal (zellij-send--askq-signature a)
                   (zellij-send--askq-signature
                    (zellij-send--askq-parse zellij-send-test--askq-single))))
    (should-not (equal (zellij-send--askq-signature a)
                       (zellij-send--askq-signature b)))))

;;; スラッシュコマンド（補完メニューの読み取り）

;; 画面は `zellij-send--process-dump' を通した後の形にしてある。
;; 罫線の行頭の ─ は削られて " ↯ ─" のような残骸になり、行末の空白は消える
;; （2026-07-29 に zellij 0.44.3 + Claude Code v2.1.220 で実測した画面が元）。

(defconst zellij-send-test--slash-menu "\
  ⏺ 準備できました。
  /doctor                       Health-check the user's Claude Code setup and fix issues: diagnose installation health
                                MCP servers, and plugins versus their context cost and disable dead weight
  /ndl                          国立国会図書館(NDL)のデジタルコレクション・NDLサーチを使う作業。
                                「デジタルコレクション」「このメモの本のURL」 (user)
 ↯ ─
❯ /

  ⏵⏵ auto mode on (shift+tab to cycle)
")

(defconst zellij-send-test--slash-menu-filtered "\
  /cd                           Move this session to a new working directory
  /copy                         Copy Claude's last response to clipboard
  /clear                        Start a new session with empty context
  /color                        Set the prompt bar color for this session
  /chrome                       Open Claude in Chrome settings
 ↯ ─
❯ /c
")

(defconst zellij-send-test--slash-idle "\
⏺ 終わりました。
 ↯ ─
❯ Try \"fix lint errors\"

  ⏵⏵ auto mode on (shift+tab to cycle)
")

(ert-deftest zellij-send-test-slash-menu-entries ()
  "説明が折り返しても、続き行を選択肢として拾わない。"
  (let ((entries (zellij-send--slash-menu-entries zellij-send-test--slash-menu)))
    (should (equal (mapcar #'car entries) '("/doctor" "/ndl")))
    (should (string-prefix-p "Health-check" (cdr (car entries))))))

(ert-deftest zellij-send-test-slash-menu-entries-order ()
  "メニューは画面と同じ上から下の順で返す。"
  (should (equal (mapcar #'car (zellij-send--slash-menu-entries
                                zellij-send-test--slash-menu-filtered))
                 '("/cd" "/copy" "/clear" "/color" "/chrome"))))

(ert-deftest zellij-send-test-slash-menu-entries-none ()
  "メニューが出ていない画面からは何も拾わない。
本文に紛れた似た行を候補にしてしまわないこと。"
  (should-not (zellij-send--slash-menu-entries zellij-send-test--slash-idle)))

(ert-deftest zellij-send-test-slash-input-text ()
  "入力欄は一番下の ❯ 行。プレースホルダも中身として読む。"
  (should (equal (zellij-send--slash-input-text zellij-send-test--slash-menu) "/"))
  (should (equal (zellij-send--slash-input-text zellij-send-test--slash-idle)
                 "Try \"fix lint errors\"")))

(ert-deftest zellij-send-test-slash-idle-p ()
  "入力欄が空（またはプレースホルダ）のときだけ操作してよい。
書きかけのテキストを Ctrl+U で消してしまわないための判定。"
  (should (zellij-send--slash-idle-p zellij-send-test--slash-idle))
  (should-not (zellij-send--slash-idle-p zellij-send-test--slash-menu))
  ;; 選択肢プロンプトが出ている間は矢印キーがそちらに効くので触らない
  (should-not (zellij-send--slash-idle-p
               (concat zellij-send-test--askq-single "\n ↯ ─\n❯\n"))))

(ert-deftest zellij-send-test-slash-arg-hint ()
  "`/name ' まで打つと引数ヒントが出る。出ないコマンドは引数なし。"
  (should (equal (zellij-send--slash-arg-hint
                  " ↯ ─\n❯ /effort  [low|medium|high|xhigh|max|ultracode|auto]\n"
                  "/effort")
                 "low|medium|high|xhigh|max|ultracode|auto"))
  (should (equal (zellij-send--slash-arg-hint " ↯ ─\n❯ /model  [model]\n" "/model")
                 "model"))
  ;; 山括弧の形もある。角括弧だけを見ると「引数なし」と誤判定する
  (should (equal (zellij-send--slash-arg-hint " ↯ ─\n❯ /add-dir  <path>\n" "/add-dir")
                 "path"))
  (should-not (zellij-send--slash-arg-hint " ↯ ─\n❯ /agents\n" "/agents"))
  ;; 別のコマンドのヒントを読み違えない（画面がまだ前の状態のとき）
  (should-not (zellij-send--slash-arg-hint " ↯ ─\n❯ /effort  [low|high]\n" "/model")))


;;; スラッシュコマンドの引数（ヒントと候補メニュー）

;; 2026-09-06 に Claude Code v2.1.263 + zellij 0.45.1 で実測した画面。
;; コマンド一覧と同じ場所に出るが、行の先頭に `/' が付かない。

(defconst zellij-send-test--slash-arg-menu "\
⚠ 4 MCP servers need authentication · run /mcp
  agentPushNotifEnabled=     true | false
  artifacts=                 true | false
  autoCompact=               true | false
 ↯ ─
❯ /config
")

(defconst zellij-send-test--slash-arg-menu-wrapped "\
  42crunch-api-security-testing@claude-plugins-official     Automate API security directly in Claude Code with 42Crunch
                                                            detect vulnerabilities aligned with OWASP API Security risks
  activecampaign@claude-plugins-official                    Marketing automation, CRM, and email marketing
 ↯ ─
❯ /plugin install
")

(ert-deftest zellij-send-test-slash-arg-entries ()
  "引数の候補メニューを画面の順のまま拾う。本文の行は拾わない。"
  (let ((entries (zellij-send--slash-arg-entries
                  zellij-send-test--slash-arg-menu)))
    (should (equal (mapcar #'car entries)
                   '("agentPushNotifEnabled=" "artifacts=" "autoCompact=")))
    (should (equal (cdr (car entries)) "true | false"))))

(ert-deftest zellij-send-test-slash-arg-entries-wrapped ()
  "説明が折り返しても続き行を候補にしない。"
  (should (equal (mapcar #'car (zellij-send--slash-arg-entries
                                zellij-send-test--slash-arg-menu-wrapped))
                 '("42crunch-api-security-testing@claude-plugins-official"
                   "activecampaign@claude-plugins-official"))))

(ert-deftest zellij-send-test-slash-arg-entries-not-commands ()
  "コマンド一覧（`/name' 始まり）を引数の候補と読み違えない。"
  (should-not (zellij-send--slash-arg-entries zellij-send-test--slash-menu))
  (should-not (zellij-send--slash-arg-entries zellij-send-test--slash-idle)))

(ert-deftest zellij-send-test-slash-hint-values ()
  "ヒントから選択肢を取り出す。入れ子・複数グループの形も実在する。"
  (should (equal (zellij-send--slash-hint-values
                  "low|medium|high|xhigh|max|ultracode|auto")
                 '("low" "medium" "high" "xhigh" "max" "ultracode" "auto")))
  ;; `[codex|gemini] [--dry-run]' の中身。2 つ目のグループは候補にしない
  (should (equal (zellij-send--slash-hint-values "codex|gemini] [--dry-run")
                 '("codex" "gemini")))
  ;; `<...>' は自由入力なので落とす
  (should (equal (zellij-send--slash-hint-values "open|share|<description>")
                 '("open" "share")))
  (should (equal (zellij-send--slash-hint-values
                  "reconnect <server>|enable|disable [<server>|all")
                 '("reconnect" "enable" "disable" "all")))
  ;; 1 つだけ残る形もある（`[auto|<tokens>]'）。候補に無い値も打てるので出す
  (should (equal (zellij-send--slash-hint-values "auto|<tokens>") '("auto")))
  ;; 選択肢ではないヒントからは候補を作らない
  (should-not (zellij-send--slash-hint-values "model"))
  (should-not (zellij-send--slash-hint-values "what to design")))

(ert-deftest zellij-send-test-slash-hint-kind ()
  "パスを求めるヒントは Emacs 側で補完する。"
  (should (eq (zellij-send--slash-hint-kind "path") 'directory))
  (should (eq (zellij-send--slash-hint-kind "dir") 'directory))
  (should (eq (zellij-send--slash-hint-kind "filename") 'file))
  (should-not (zellij-send--slash-hint-kind "model"))
  (should-not (zellij-send--slash-hint-kind "low|medium|high")))

(ert-deftest zellij-send-test-slash-arg-append ()
  "候補はトークン全体で返るので、書きかけのトークンは置き換える。
置き換えるかは画面から推測せず、打った側が覚えている（第 3 引数）。"
  (should (equal (zellij-send--slash-arg-append "" "enable") "enable"))
  (should (equal (zellij-send--slash-arg-append "enable" "myplugin")
                 "enable myplugin"))
  ;; `/config autoScroll=' の次の候補は `autoScroll=true'。足すと壊れる
  (should (equal (zellij-send--slash-arg-append "autoScroll=" "autoScroll=true" t)
                 "autoScroll=true"))
  ;; 絞り込みに打った `air' に続けて選んだ候補も置き換える
  (should (equal (zellij-send--slash-arg-append "install air" "airwallex@x" t)
                 "install airwallex@x"))
  ;; 確定したトークンの後ろは足す。候補が偶然そのトークンで始まっても同じ
  (should (equal (zellij-send--slash-arg-append "install" "install-helper@x")
                 "install install-helper@x")))

(ert-deftest zellij-send-test-slash-probe-text ()
  "続きを聞くために打つ文字列。書きかけのトークンには空白を足さない
（空白を足すと絞り込みが解除されて別の候補が出る）。"
  (should (equal (zellij-send--slash-probe-text "/config" "") "/config "))
  (should (equal (zellij-send--slash-probe-text "/config" "autoScroll=")
                 "/config autoScroll="))
  (should (equal (zellij-send--slash-probe-text "/plugin" "install air" t)
                 "/plugin install air"))
  (should (equal (zellij-send--slash-probe-text "/plugin" "enable")
                 "/plugin enable ")))

;;; transcript（Claude Code の会話履歴）

(defconst zellij-send-test--transcript
  (concat
   ;; 会話でない行。捨てる
   "{\"type\":\"mode\",\"mode\":\"normal\"}\n"
   "{\"type\":\"file-history-snapshot\",\"messageId\":\"x\"}\n"
   ;; user は素の文字列のことがある
   "{\"type\":\"user\",\"timestamp\":\"2026-08-02T12:28:32.618Z\","
   "\"message\":{\"content\":\"こんにちは\"}}\n"
   "{\"type\":\"assistant\",\"timestamp\":\"2026-08-02T12:28:36.359Z\","
   "\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"考え中\"},"
   "{\"type\":\"text\",\"text\":\"やります\"},"
   "{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}\n"
   "{\"type\":\"user\",\"timestamp\":\"2026-08-02T12:28:37.010Z\","
   "\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"a.txt\","
   "\"is_error\":false}]}}\n"
   ;; 書き込み中の壊れた末尾行。読み飛ばす
   "{\"type\":\"assist")
  "テスト用の transcript（実データの形を写したもの）。")

(ert-deftest zellij-send-test-transcript-slug ()
  "作業ディレクトリ名は英数字以外がすべて `-' になる。"
  (should (equal (zellij-send--transcript-slug "/Users/mck/Documents/github/zellij-send")
                 "-Users-mck-Documents-github-zellij-send"))
  ;; ドットも `-' になる（`.claude' が `-claude' で 2 連続の `-' になる）
  (should (equal (zellij-send--transcript-slug "/Users/mck/.claude")
                 "-Users-mck--claude"))
  ;; 末尾のスラッシュは落とす（付いたままだと余分な `-' が増える）
  (should (equal (zellij-send--transcript-slug "/Users/mck/tmp/")
                 "-Users-mck-tmp"))
  ;; 空白も `-' になる
  (should (equal (zellij-send--transcript-slug "/Users/mck/My Drive/memo")
                 "-Users-mck-My-Drive-memo")))

(ert-deftest zellij-send-test-transcript-entries ()
  "会話の行だけを、ブロックごとに順番どおり取り出す。"
  (let ((es (zellij-send--transcript-entries zellij-send-test--transcript)))
    (should (= (length es) 5))
    (should (equal (mapcar (lambda (e) (plist-get e :kind)) es)
                   '("text" "thinking" "text" "tool_use" "tool_result")))
    (should (equal (mapcar (lambda (e) (plist-get e :role)) es)
                   '("user" "assistant" "assistant" "assistant" "user")))
    (should (equal (plist-get (nth 0 es) :body) "こんにちは"))
    (should (equal (plist-get (nth 3 es) :name) "Bash"))
    ;; is_error が偽なら「エラー」印は付かない
    (should-not (plist-get (nth 4 es) :name))
    (should (equal (plist-get (nth 4 es) :body) "a.txt"))))

(ert-deftest zellij-send-test-transcript-format ()
  "役割が変わったところにだけ見出しを置き、text 以外に小見出しを付ける。"
  (let* ((es (zellij-send--transcript-entries zellij-send-test--transcript))
         (zellij-send-transcript-max-block-lines nil)
         (out (zellij-send--transcript-format es)))
    (should (string-prefix-p "## user" out))
    ;; assistant の 3 ブロックで見出しは 1 回だけ。
    ;; tool_result は role が "user" だが「user」に混ぜず "tool" にする
    ;; 時刻はタイムゾーンで変わるので、見出しの名前だけを見る
    (should (equal (mapcar (lambda (l) (car (split-string l "  ")))
                           (seq-filter (lambda (l) (string-prefix-p "## " l))
                                       (split-string out "\n")))
                   '("## user" "## assistant" "## tool")))
    (should (string-match-p "^### thinking$" out))
    (should (string-match-p "^### tool_use  Bash$" out))
    ;; text には小見出しを付けない
    (should-not (string-match-p "### text" out))))

(ert-deftest zellij-send-test-transcript-trim ()
  "行数上限を設けたときだけ切り詰める。"
  (let ((body "1\n2\n3\n4"))
    (let ((zellij-send-transcript-max-block-lines nil))
      (should (equal (zellij-send--transcript-trim body) body)))
    (let ((zellij-send-transcript-max-block-lines 10))
      (should (equal (zellij-send--transcript-trim body) body)))
    (let ((zellij-send-transcript-max-block-lines 2))
      (should (equal (zellij-send--transcript-trim body)
                     "1\n2\n… （残り 2 行）")))))

(ert-deftest zellij-send-test-transcript-clip ()
  "長すぎる 1 行だけを切る。短い行と改行の並びは変えない。"
  (let ((zellij-send-transcript-max-line-length 10))
    ;; 上限ちょうどは切らない
    (should (equal (zellij-send--transcript-clip "0123456789") "0123456789"))
    (should (equal (zellij-send--transcript-clip "abc\ndef") "abc\ndef"))
    ;; 1 行が長いときだけ切り、残り文字数を添える
    (should (equal (zellij-send--transcript-clip "0123456789abc")
                   "0123456789…（この行はあと 3 文字）"))
    ;; 長い行と短い行が混ざっても、短い行はそのまま
    (should (equal (zellij-send--transcript-clip "ok\n0123456789abc\nok")
                   "ok\n0123456789…（この行はあと 3 文字）\nok"))
    ;; 文字数で数える（バイト数ではない）
    (should (equal (zellij-send--transcript-clip "あいうえおかきくけこさ")
                   "あいうえおかきくけこ…（この行はあと 1 文字）")))
  ;; nil なら切らない
  (let ((zellij-send-transcript-max-line-length nil))
    (should (equal (zellij-send--transcript-clip (make-string 5000 ?x))
                   (make-string 5000 ?x)))))

(ert-deftest zellij-send-test-transcript-block ()
  "画像ブロックは base64 を出さず要約にする。"
  (let ((img '((type . "image")
               (source . ((type . "base64")
                          (media_type . "image/png")
                          (data . "AAAABBBBCCCCDDDD"))))))
    (should (equal (zellij-send--transcript-block img) "[画像 image/png 12 B]"))
    ;; base64 の中身が出ていないこと（これが本題）
    (should-not (string-match-p "AAAA" (zellij-send--transcript-block img))))
  ;; データが無くても落ちない
  (should (equal (zellij-send--transcript-block
                  '((type . "image") (source . ((media_type . "image/jpeg")))))
                 "[画像 image/jpeg]"))
  ;; 大きさは人が読める単位にする
  (let ((big `((type . "image")
               (source . ((media_type . "image/png")
                          (data . ,(make-string 1400000 ?A)))))))
    (should (equal (zellij-send--transcript-block big) "[画像 image/png 1.0 MB]")))
  ;; 画像以外のブロックは従来どおり
  (should (string-match-p "unknown" (zellij-send--transcript-block
                                     '((type . "unknown") (foo . 1))))))

(ert-deftest zellij-send-test-transcript-entries-image ()
  "tool_result に画像が入っていても base64 が本文に混ざらない。"
  (let* ((line (json-encode
                '((type . "user")
                  (message . ((content . (((type . "tool_result")
                                           (content . (((type . "image")
                                                        (source . ((media_type . "image/png")
                                                                   (data . "QUJDREVGRw=="))))))))))))))
         (entries (zellij-send--transcript-entries line))
         (body (plist-get (car entries) :body)))
    (should (= (length entries) 1))
    (should (string-match-p "\\[画像 image/png" body))
    (should-not (string-match-p "QUJDREVG" body))))


;;; セッションのコマンド（多 CLI 対応）

(ert-deftest zellij-send-test-command-name ()
  "起動コマンドからエージェント名を取り出す。"
  (should (equal (zellij-send--command-name "claude") "claude"))
  (should (equal (zellij-send--command-name "/usr/local/bin/claude --resume")
                 "claude"))
  ;; インタプリタ経由でも `zellij-send-commands' の名前を拾う
  ;; （実測: codex は `node /opt/homebrew/bin/codex' として COMMAND 列に出る）
  (should (equal (zellij-send--command-name "node /opt/homebrew/bin/codex")
                 "codex"))
  ;; **インタプリタ以外の引数は見ない**。全トークンを見ていた頃は
  ;; `cat /tmp/claude' が claude 判定になっていた（astra の指摘）
  (should (equal (zellij-send--command-name "cat /tmp/claude") "cat"))
  (should (equal (zellij-send--command-name "grep claude foo.txt") "grep"))
  ;; インタプリタでも既知の名前が無ければインタプリタ自身の名前
  (should (equal (zellij-send--command-name "node server.js") "node"))
  ;; 一覧に無ければ先頭トークンの実行ファイル名
  (should (equal (zellij-send--command-name "/bin/zsh -l") "zsh"))
  (should-not (zellij-send--command-name ""))
  (should-not (zellij-send--command-name nil)))

(ert-deftest zellij-send-test-slash-supported-p ()
  "共通スラッシュコマンドは対応表にあるエージェントにだけ送る。"
  (with-temp-buffer
    (let ((zellij-send-default-command "claude"))
      (setq-local zellij-send--command "claude")
      (should (zellij-send--slash-supported-p "/compact"))
      (should (zellij-send--slash-supported-p "/clear"))
      (setq-local zellij-send--command "node /opt/homebrew/bin/codex")
      (should (zellij-send--slash-supported-p "/compact"))
      ;; agy に /compact は無い（実測: 補完メニューで `No matches'）
      (setq-local zellij-send--command "agy")
      (should (zellij-send--slash-supported-p "/clear"))
      (should-not (zellij-send--slash-supported-p "/compact"))
      ;; 対応が判らない CLI には送らない
      (setq-local zellij-send--command "/bin/zsh")
      (should-not (zellij-send--slash-supported-p "/compact"))
      ;; コマンド不明でも既定値（claude）で代用しない
      (setq-local zellij-send--command nil)
      (should-not (zellij-send--slash-supported-p "/compact"))
      ;; 表に無いコマンドはどのエージェントでも送らない
      (setq-local zellij-send--command "claude")
      (should-not (zellij-send--slash-supported-p "/doctor")))))

(ert-deftest zellij-send-test-progress-file ()
  "作業内容を書かせる先はエージェントごとに変える。"
  (with-temp-buffer
    (let ((zellij-send-default-command "claude"))
      (setq-local zellij-send--command "claude")
      (should (equal (zellij-send--progress-file) "CLAUDE.md"))
      (setq-local zellij-send--command "node /opt/homebrew/bin/codex")
      (should (equal (zellij-send--progress-file) "AGENTS.md"))
      (setq-local zellij-send--command "agy")
      (should (equal (zellij-send--progress-file) "GEMINI.md"))
      ;; 知らないエージェントには既定値
      (setq-local zellij-send--command "/bin/zsh")
      (should (equal (zellij-send--progress-file)
                     zellij-send-progress-file-default)))))

(ert-deftest zellij-send-test-claude-p ()
  "Claude Code のときだけ画面解析・transcript の経路に入る。
判定はバッファローカルの `zellij-send--command' が優先で、
空のときだけ `zellij-send-default-command' を使う。"
  (with-temp-buffer
    (let ((zellij-send-default-command "claude"))
      ;; バッファローカルが空なら既定値で判定（従来どおり）
      (should (zellij-send--claude-p))
      ;; codex を動かしているバッファでは既定値が claude でも non-claude
      (setq-local zellij-send--command "node /opt/homebrew/bin/codex")
      (should-not (zellij-send--claude-p))
      (should (equal (zellij-send--buffer-command) "codex"))
      (setq-local zellij-send--command "/usr/local/bin/claude --resume")
      (should (zellij-send--claude-p)))
    (let ((zellij-send-default-command "zsh"))
      ;; 既定値が claude でなくても、このバッファが claude なら claude 扱い
      (should (zellij-send--claude-p))
      (setq-local zellij-send--command nil)
      (should-not (zellij-send--claude-p)))))

(defconst zellij-send-test--panes-all "\
PANE_ID  TYPE  TITLE  COMMAND  CWD  FOCUSED  FLOATING  EXITED
plugin_0  plugin  (.) - zellij:link  zellij:link  -  false  false  false
terminal_0  terminal  zellij-send  node /opt/homebrew/bin/codex  /tmp/x  true  false  false
terminal_1  terminal  claude  claude  /tmp/x  false  false  true"
  "`action list-panes --all' の出力の実例（列は 2 個以上の空白区切り）。
TITLE（`(.) - zellij:link'）と COMMAND（`node /opt/…'）に単独の空白が入る。")

(ert-deftest zellij-send-test-pane-field ()
  "ヘッダ行から列位置を求めるので、TITLE や COMMAND の空白に影響されない。"
  (should (equal (zellij-send--pane-field zellij-send-test--panes-all
                                          "terminal_0" "COMMAND")
                 "node /opt/homebrew/bin/codex"))
  (should (equal (zellij-send--pane-field zellij-send-test--panes-all
                                          "terminal_1" "EXITED")
                 "true"))
  ;; 無い pane-id・無い列・ヘッダの無い出力では nil
  (should-not (zellij-send--pane-field zellij-send-test--panes-all
                                       "terminal_9" "COMMAND"))
  (should-not (zellij-send--pane-field zellij-send-test--panes-all
                                       "terminal_0" "NOPE"))
  (should-not (zellij-send--pane-field "" "terminal_0" "COMMAND")))

(ert-deftest zellij-send-test-parse-terminal-panes ()
  "端末ペインだけを (ID COMMAND EXITED-P) で拾う。
TITLE は当てにならない（ターミナルから作ったセッションでは
codex のペインのタイトルがセッション名になっていた。実測）ので COMMAND を見る。"
  (should (equal (zellij-send--parse-terminal-panes zellij-send-test--panes-all)
                 '(("terminal_0" "node /opt/homebrew/bin/codex" nil)
                   ("terminal_1" "claude" t))))
  ;; plugin ペインは落ちる（CWD が `-' でも列位置で読むので取り違えない）
  (should-not (assoc "plugin_0"
                     (zellij-send--parse-terminal-panes zellij-send-test--panes-all)))
  (should-not (zellij-send--parse-terminal-panes ""))
  (should-not (zellij-send--parse-terminal-panes "ヘッダの無い出力")))

(ert-deftest zellij-send-test-parse-pane-exited-shared-parser ()
  "EXITED 列も COMMAND 列と同じ `zellij-send--pane-field' で読む。
既存の `zellij-send-test-parse-pane-exited' と合わせて、
共通化しても 3 値（t / nil / :unknown）が変わらないことを確かめる。"
  (should (eq (zellij-send--parse-pane-exited zellij-send-test--panes-all
                                              "terminal_1")
              t))
  (should (eq (zellij-send--parse-pane-exited zellij-send-test--panes-all
                                              "terminal_0")
              nil))
  (should (eq (zellij-send--parse-pane-exited zellij-send-test--panes-all
                                              "terminal_9")
              :unknown))
  (should (eq (zellij-send--parse-pane-exited "" "terminal_0") :unknown)))

(ert-deftest zellij-send-test-pick-pane ()
  "既定のコマンド → 一覧にある他 CLI → 先頭、の順。生きているペインを優先。"
  (let ((zellij-send-default-command "claude")
        (zellij-send-commands '("claude" "codex")))
    ;; デフォルト shell ペインが残っていてもエージェントのペインを選ぶ
    (should (equal (zellij-send--pick-pane '(("terminal_0" "/bin/zsh" nil)
                                             ("terminal_1" "claude" nil)))
                   "terminal_1"))
    ;; claude が無ければ一覧にある他の CLI（インタプリタ経由でも拾う）
    (should (equal (zellij-send--pick-pane
                    '(("terminal_0" "/bin/zsh" nil)
                      ("terminal_1" "node /opt/homebrew/bin/codex" nil)))
                   "terminal_1"))
    ;; どれも無ければ最初の端末ペイン
    (should (equal (zellij-send--pick-pane '(("terminal_0" "/bin/zsh" nil)
                                             ("terminal_1" "bash" nil)))
                   "terminal_0"))
    ;; 終了済みの claude より、生きている shell を先に選ぶ
    (should (equal (zellij-send--pick-pane '(("terminal_0" "claude" t)
                                             ("terminal_1" "/bin/zsh" nil)))
                   "terminal_1"))
    ;; 全部終了していれば同じ順で終了済みから選ぶ（最後の画面を読むため）
    (should (equal (zellij-send--pick-pane '(("terminal_0" "/bin/zsh" t)
                                             ("terminal_1" "claude" t)))
                   "terminal_1"))
    ;; COMMAND が読めなかったペイン（nil）でも落ちない
    (should (equal (zellij-send--pick-pane '(("terminal_0" nil nil))) "terminal_0"))
    (should-not (zellij-send--pick-pane nil))))


;;; 選択肢プロンプトの検出（claude の ❯ と codex の ›）

(ert-deftest zellij-send-test-detect-prompt ()
  "`❯ 1.' と `› 1.' の両方を選択肢プロンプトとして拾う。
3 つの CLI で行の形は同じで記号だけが違う（すべて実測）:
claude `❯ 1. りんご' / codex `› 1. gpt-6-astra (current)' /
agy `> 1. Yes'（コマンド実行の許可ダイアログ）。"
  (dolist (marker '("❯" "›" ">"))
    (with-temp-buffer
      (insert "好きな果物はどれですか？\n"
              "  " marker " 1. りんご\n"
              "    2. みかん\n")
      (should (zellij-send--detect-prompt))
      ;; ハイライトの正規表現も同じ行に当たる
      (goto-char (point-min))
      (should (re-search-forward (zellij-send--prompt-regexp t) nil t))))
  ;; 10 番以降も拾う
  (with-temp-buffer
    (insert "  ❯ 12. じゅうにばんめ\n")
    (should (zellij-send--detect-prompt)))
  ;; 入力欄（記号のあとに数字が来ない）はプロンプトではない
  (with-temp-buffer
    (insert "› Ask Codex to do anything\n")
    (should-not (zellij-send--detect-prompt)))
  (with-temp-buffer
    (insert "❯ /effort high\n")
    (should-not (zellij-send--detect-prompt)))
  ;; 行頭に限定する。本文中に引用された選択肢は拾わない（astra の指摘）
  (with-temp-buffer
    (insert "画面には ❯ 1. りんご のように出ます\n")
    (should-not (zellij-send--detect-prompt))))

(ert-deftest zellij-send-test-number-reply ()
  "数字での回答は実測で確認できたエージェントにだけ許す。
codex は数字キーを選択として受け付けない（実測）ので一覧に入れない。"
  (with-temp-buffer
    (let ((zellij-send-default-command "claude"))
      (setq-local zellij-send--command "claude")
      (should-not (zellij-send--assert-number-reply))
      (setq-local zellij-send--command "agy")
      (should-not (zellij-send--assert-number-reply))
      (setq-local zellij-send--command "node /opt/homebrew/bin/codex")
      (should-error (zellij-send--assert-number-reply) :type 'user-error)
      ;; コマンド不明でも既定値（claude）で代用しない
      (setq-local zellij-send--command nil)
      (should-error (zellij-send--assert-number-reply) :type 'user-error))))

(ert-deftest zellij-send-test-claude-confirmed-p ()
  "ペインに打ち込む機能は、コマンドが確定している claude のときだけ許す。
`zellij-send--command' が nil のときに既定値で代用すると、
codex のペインに `/' を打ち込む。"
  (with-temp-buffer
    (let ((zellij-send-default-command "claude"))
      ;; コマンド不明: 読むだけの `--claude-p' は t でも、打ち込む方は不可
      (should (zellij-send--claude-p))
      (should-not (zellij-send--agent-name))
      (should-not (zellij-send--claude-confirmed-p))
      (should-not (zellij-send--slash-supported-p "/compact"))
      (setq-local zellij-send--command "claude")
      (should (zellij-send--claude-confirmed-p))
      (setq-local zellij-send--command "node /opt/homebrew/bin/codex")
      (should (equal (zellij-send--agent-name) "codex"))
      (should-not (zellij-send--claude-confirmed-p)))))

;;; セッションの連番（同じプロジェクトで複数エージェント）

(ert-deftest zellij-send-test-numbered-session-name ()
  "1 体目から 2 桁の連番が付き、空いている最小の番号を使う。"
  (should (equal (zellij-send--numbered-session-name "myproj" nil) "myproj00"))
  (should (equal (zellij-send--numbered-session-name "myproj" '("myproj00"))
                 "myproj01"))
  ;; 途中が空いていればそこを埋める（01 を終了した後に増やす場合）
  (should (equal (zellij-send--numbered-session-name
                  "myproj" '("myproj00" "myproj02"))
                 "myproj01"))
  ;; 別プロジェクトの名前は邪魔しない
  (should (equal (zellij-send--numbered-session-name "myproj" '("other00"))
                 "myproj00"))
  ;; 10 以上も 2 桁のまま
  (should (equal (zellij-send--numbered-session-name
                  "p" (mapcar (lambda (n) (format "p%02d" n)) (number-sequence 0 9)))
                 "p10")))

(ert-deftest zellij-send-test-session-base ()
  "連番サフィックスだけを剥がす。剥がしすぎない。"
  (should (equal (zellij-send--session-base "myproj00") "myproj"))
  (should (equal (zellij-send--session-base "myproj12") "myproj"))
  ;; 連番が付いていない従来のセッション名はそのまま
  (should (equal (zellij-send--session-base "myproj") "myproj"))
  ;; 基底名自体が数字で終わる場合、剥がすのは末尾 2 桁だけ
  (should (equal (zellij-send--session-base "project200") "project2"))
  ;; 1 桁しかなければ連番ではない
  (should (equal (zellij-send--session-base "myproj1") "myproj1")))

(provide 'zellij-send-test)

;;; zellij-send-test.el ends here
