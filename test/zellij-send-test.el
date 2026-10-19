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
(require 'zellij-send-dashboard)

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

;;; zellij-send--normalize-screen / zellij-send--screen-for-display

(ert-deftest zellij-send-test-normalize-screen-trailing-spaces ()
  "subscribe の viewport が付ける行末パディングを削る。"
  (should (equal (zellij-send--normalize-screen
                  (concat "日本語の行" (make-string 300 ?\s) "\n"
                          (make-string 320 ?\s) "\n"
                          "次の行" (make-string 10 ?\s)))
                 "日本語の行\n\n次の行")))

(ert-deftest zellij-send-test-normalize-screen-trailing-blank-lines ()
  "画面下端の連続空行（パディングだけの行）をまとめて落とす。"
  (should (equal (zellij-send--normalize-screen
                  (concat "本文\n" (make-string 320 ?\s) "\n   \n\n"))
                 "本文")))

(ert-deftest zellij-send-test-normalize-screen-keeps-inner-blanks-and-indent ()
  "本文中の空行と行頭のインデントは保つ。"
  (should (equal (zellij-send--normalize-screen "  上\t \n\n  下  ")
                 "  上\n\n  下")))

;; 入力欄が最下段にあるので、500 行の画面では起動直後に約 485 行の空行が挟まる
(ert-deftest zellij-send-test-screen-for-display-collapses-blank-run ()
  "長い空行の連なりを `zellij-send-max-blank-lines' まで詰め、短いものは残す。
詰めるのは表示形だけで、正規形（パーサが読む形）は設定に左右されない。"
  (let ((raw (concat "ロゴ\n\n本文" (make-string 485 ?\n) "❯ 入力欄\n\n  ⏵⏵ auto")))
    (let ((zellij-send-max-blank-lines 2))
      (should (equal (zellij-send--screen-for-display raw)
                     "ロゴ\n\n本文\n\n\n❯ 入力欄\n\n  ⏵⏵ auto"))
      ;; ちょうど上限の連なりはそのまま
      (should (equal (zellij-send--screen-for-display "上\n\n\n下") "上\n\n\n下")))
    (let ((zellij-send-max-blank-lines 0))
      (should (equal (zellij-send--screen-for-display raw)
                     "ロゴ\n本文\n❯ 入力欄\n  ⏵⏵ auto")))
    (let ((zellij-send-max-blank-lines nil))
      (should (equal (zellij-send--screen-for-display raw)
                     (concat "ロゴ\n\n本文" (make-string 485 ?\n)
                             "❯ 入力欄\n\n  ⏵⏵ auto"))))
    (let ((zellij-send-max-blank-lines 0))
      (should (equal (zellij-send--normalize-screen raw) raw)))))

(ert-deftest zellij-send-test-screen-for-display-borders ()
  "罫線の行頭の ─ は表示形でだけ削る。正規形は罫線をそのまま持つ。"
  (let ((raw "本文\n────────\n❯ 入力欄\n──────── ↯ ─\n  ⏵⏵ auto\n────"))
    (should (equal (zellij-send--normalize-screen raw) raw))
    (should (equal (zellij-send--screen-for-display (zellij-send--normalize-screen raw))
                   "本文\n\n❯ 入力欄\n ↯ ─\n  ⏵⏵ auto"))))

(ert-deftest zellij-send-test-trim-end ()
  "末尾の指定文字だけを落とし、途中と先頭は残す。"
  (should (equal (zellij-send--trim-end "  A   B \t " '(?\s ?\t)) "  A   B"))
  (should (equal (zellij-send--trim-end "   " '(?\s)) ""))
  (should (equal (zellij-send--trim-end "" '(?\s)) ""))
  (should (equal (zellij-send--trim-end "上\n\n下\n\n" '(?\n)) "上\n\n下")))

(ert-deftest zellij-send-test-normalize-screen-wide-inner-gap ()
  "列の間が大きく空いた行も、行末だけ削って中の空白は保つ。
正規表現で行末を削っていたころは、この形で 1 画面 45 ms かかっていた。"
  (let* ((line (concat "A" (make-string 318 ?\s) "B"))
         (raw (mapconcat #'identity (make-list 78 (concat line "  ")) "\n")))
    (should (equal (zellij-send--normalize-screen raw)
                   (mapconcat #'identity (make-list 78 line) "\n")))))

(ert-deftest zellij-send-test-normalize-screen-strips-ansi-then-spaces ()
  "ANSI を除去した結果の行末空白も削る（除去順の確認）。"
  (should (equal (zellij-send--normalize-screen "本文\033[0m   \n")
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

;; 画面は `zellij-send--process-dump'（2026-10-19 に `--normalize-screen' と
;; `--screen-for-display' に分けた）を通した後の形にしてある。罫線の残骸の形は
;; 今の正規形とは違うが、パーサはどちらも読めるので古い形の見本として残す。
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
  ;; 入れ子の括弧の中（`disable' の引数の `all'）は最上位の候補にしない
  (should (equal (zellij-send--slash-hint-values
                  "reconnect <server>|enable|disable [<server>|all")
                 '("reconnect" "enable" "disable")))
  ;; v2.1.303 の `/effort'（`ultracode' の引数の on/off を候補にしない）
  (should (equal (zellij-send--slash-hint-values
                  "low|medium|high|xhigh|max|auto|ultracode [on|off]")
                 '("low" "medium" "high" "xhigh" "max" "auto" "ultracode")))
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

(ert-deftest zellij-send-test-launch-command ()
  "Remote Control 付きの起動コマンドを組み立てる。"
  ;; 無効なら何も足さない
  (let ((zellij-send-remote-control nil))
    (should (equal (zellij-send--launch-command "claude" "p00") "claude"))
    ;; ただし既に付いていれば、名前だけ新しいセッションに付け替える
    ;; （add-agent が前のセッションの名前を引き継がないように）
    (should (equal (zellij-send--launch-command "claude --remote-control p00" "p01")
                   "claude --remote-control p01")))
  (let ((zellij-send-remote-control t))
    (should (equal (zellij-send--launch-command "claude" "p00")
                   "claude --remote-control p00"))
    (should (equal (zellij-send--launch-command "claude --resume" "p00")
                   "claude --resume --remote-control p00"))
    ;; 名前を省いた形・後ろにオプションが続く形でも重複させない
    (should (equal (zellij-send--launch-command "claude --remote-control --verbose" "p01")
                   "claude --verbose --remote-control p01"))
    (should (equal (zellij-send--launch-command "claude --remote-control old --verbose" "p01")
                   "claude --verbose --remote-control p01"))
    ;; claude 以外には付けない
    (should (equal (zellij-send--launch-command "codex" "p00") "codex"))
    (should (equal (zellij-send--launch-command "agy" "p00") "agy"))))

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

(ert-deftest zellij-send-test-slash-capabilities ()
  "共通スラッシュコマンドは、その能力を持つと確定したエージェントにだけ送る。"
  (with-temp-buffer
    (let ((zellij-send-default-command "claude"))
      (setq-local zellij-send--command "claude")
      (should (zellij-send--confirmed-capable-p 'compact))
      (should (zellij-send--confirmed-capable-p 'clear))
      (setq-local zellij-send--command "node /opt/homebrew/bin/codex")
      (should (zellij-send--confirmed-capable-p 'compact))
      ;; agy に /compact は無い（実測: 補完メニューで `No matches'）
      (setq-local zellij-send--command "agy")
      (should (zellij-send--confirmed-capable-p 'clear))
      (should-not (zellij-send--confirmed-capable-p 'compact))
      (should-error (zellij-send--assert-capability 'compact) :type 'user-error)
      ;; 対応が判らない CLI には送らない
      (setq-local zellij-send--command "/bin/zsh")
      (should-not (zellij-send--confirmed-capable-p 'compact))
      ;; コマンド不明でも既定値（claude）で代用しない
      (setq-local zellij-send--command nil)
      (should-not (zellij-send--confirmed-capable-p 'compact))
      ;; 表に無い能力はどのエージェントでも無い
      (setq-local zellij-send--command "claude")
      (should-not (zellij-send--confirmed-capable-p 'doctor)))))

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

(ert-deftest zellij-send-test-progress-request ()
  "記録の依頼は追記ではなく更新。作業ログは別ファイルへ逃がす。"
  (let ((req (zellij-send--progress-request "CLAUDE.md")))
    (should (string-match-p "CLAUDE\\.md" req))
    (should (string-match-p "追記ではなく更新" req))
    (should (string-match-p "古くなった記述は消す" req))
    (should (string-match-p "時系列" req))
    ;; 「CLAUDE.md に追記して」という旧依頼文に戻っていないこと
    (should-not (string-match-p "CLAUDE\\.md に追記" req)))
  (let ((req (zellij-send--progress-request
              "CLAUDE.md" ".zellij-send/worklog-2026-10-19.md")))
    (should (string-match-p "worklog-2026-10-19\\.md に書いて" req))
    (should (string-match-p "CLAUDE\\.md には書かないで" req))))

(ert-deftest zellij-send-test-capable-p ()
  "読むだけの機能は推測でよい。判定はバッファローカルの `zellij-send--command'
が優先で、空のときだけ `zellij-send-default-command' を使う。"
  (with-temp-buffer
    (let ((zellij-send-default-command "claude"))
      ;; バッファローカルが空なら既定値で判定（従来どおり）
      (should (zellij-send--capable-p 'transcript))
      ;; codex を動かしているバッファでは既定値が claude でも transcript は無い
      (setq-local zellij-send--command "node /opt/homebrew/bin/codex")
      (should-not (zellij-send--capable-p 'transcript))
      (should (equal (zellij-send--buffer-command) "codex"))
      (setq-local zellij-send--command "/usr/local/bin/claude --resume")
      (should (zellij-send--capable-p 'transcript))
      ;; 派生の実行ファイル名（claude-beta）も claude として扱う（旧 `string-prefix-p'）
      (setq-local zellij-send--command "claude-beta")
      (should (zellij-send--capable-p 'transcript)))
    (let ((zellij-send-default-command "zsh"))
      ;; 既定値が claude でなくても、このバッファが claude なら claude 扱い
      (setq-local zellij-send--command "claude")
      (should (zellij-send--capable-p 'output-log))
      (setq-local zellij-send--command nil)
      (should-not (zellij-send--capable-p 'output-log)))))

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

(defun zellij-send-test--prompt-p (marker &optional command)
  "MARKER を使った選択肢行を COMMAND のバッファで検出できるか返す。"
  (with-temp-buffer
    (setq-local zellij-send--command command)
    (insert "好きな果物はどれですか？\n"
            "  " marker " 1. りんご\n"
            "    2. みかん\n")
    (and (zellij-send--detect-prompt) t)))

(ert-deftest zellij-send-test-detect-prompt ()
  "`❯ 1.' と `› 1.' はどのエージェントでも拾う。
3 つの CLI で行の形は同じで記号だけが違う（すべて実測）:
claude `❯ 1. りんご' / codex `› 1. gpt-6-astra (current)' /
agy `> 1. Yes'（コマンド実行の許可ダイアログ）。"
  (dolist (marker '("❯" "›"))
    (should (zellij-send-test--prompt-p marker "claude"))
    (should (zellij-send-test--prompt-p marker "agy")))
  ;; ハイライトの正規表現も同じ行に当たる
  (with-temp-buffer
    (insert "  ❯ 1. りんご\n")
    (goto-char (point-min))
    (should (re-search-forward (zellij-send--prompt-regexp t) nil t)))
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

(ert-deftest zellij-send-test-detect-prompt-ascii-marker ()
  "ASCII の `>' は agy のバッファでだけ選択肢とみなす。

agy の許可ダイアログは `> 1. Yes' なので `>' が要るが、全 CLI で
有効にすると本文中の markdown 引用（`> 1. …'）を誤検出する。
誤検出は表示だけの問題ではない——ダッシュボードの数字キーは
`zellij-send--detect-prompt' を許可条件にしているので、選択のつもりの
数字がただの入力としてペインに届く（astra のレビューで指摘）。"
  (should (zellij-send-test--prompt-p ">" "agy"))
  (should-not (zellij-send-test--prompt-p ">" "claude"))
  (should-not (zellij-send-test--prompt-p ">" "node /opt/homebrew/bin/codex"))
  ;; コマンド不明のバッファでも `>' は拾わない
  (should-not (zellij-send-test--prompt-p ">" nil))
  ;; markdown 引用が claude の画面に出ても誤検出しない
  (with-temp-buffer
    (setq-local zellij-send--command "claude")
    (insert "> 1. まず依存を入れる\n> 2. 次にビルドする\n")
    (should-not (zellij-send--detect-prompt))))

(ert-deftest zellij-send-test-number-reply ()
  "数字での回答は実測で確認できたエージェントにだけ許す。
codex は数字キーを選択として受け付けない（実測）ので能力に入れない。"
  (with-temp-buffer
    (let ((zellij-send-default-command "claude"))
      (setq-local zellij-send--command "claude")
      (should-not (zellij-send--assert-capability 'number-reply))
      (setq-local zellij-send--command "agy")
      (should-not (zellij-send--assert-capability 'number-reply))
      (setq-local zellij-send--command "node /opt/homebrew/bin/codex")
      (should-error (zellij-send--assert-capability 'number-reply) :type 'user-error)
      ;; コマンド不明でも既定値（claude）で代用しない
      (setq-local zellij-send--command nil)
      (should-error (zellij-send--assert-capability 'number-reply) :type 'user-error))))

(ert-deftest zellij-send-test-confirmed-capable-p ()
  "ペインに打ち込む機能は、コマンドが確定しているときだけ許す。
`zellij-send--command' が nil のときに既定値で代用すると、
codex のペインに `/' を打ち込む。"
  (with-temp-buffer
    (let ((zellij-send-default-command "claude"))
      ;; コマンド不明: 読むだけの判定は t でも、打ち込む方は不可
      (should (zellij-send--capable-p 'slash-completion))
      (should-not (zellij-send--agent-name))
      (should-not (zellij-send--confirmed-capable-p 'slash-completion))
      (should-not (zellij-send--confirmed-capable-p 'compact))
      (setq-local zellij-send--command "claude")
      (should (zellij-send--confirmed-capable-p 'slash-completion))
      (setq-local zellij-send--command "node /opt/homebrew/bin/codex")
      (should (equal (zellij-send--agent-name) "codex"))
      (should-not (zellij-send--confirmed-capable-p 'slash-completion)))))

(ert-deftest zellij-send-test-capability-error-messages ()
  "断るときの文面は、対応表にまとめる前と 1 字も変えない。"
  (cl-flet ((msg (cap command)
              (with-temp-buffer
                (setq-local zellij-send--command command)
                (condition-case err
                    (progn (zellij-send--assert-capability cap) nil)
                  (user-error (cadr err))))))
    (should (equal (msg 'number-reply "node /opt/homebrew/bin/codex")
                   "数字での回答は codex では確認できていません。C-c C-t のキー透過モードで ↑↓ と RET を使ってください"))
    (should (equal (msg 'compact "agy")
                   "/compact に対応しているか判らないので送りません（agy）。本文として送るなら C-c C-c を使ってください"))
    (should (equal (msg 'clear nil)
                   "/clear に対応しているか判らないので送りません（コマンド不明）。本文として送るなら C-c C-c を使ってください"))
    (should (equal (msg 'slash-completion "agy")
                   "スラッシュコマンドの補完は Claude Code 専用です（agy）。本文として送るか C-c C-t のキー透過モードを使ってください"))
    (should (equal (msg 'askq "node /opt/homebrew/bin/codex")
                   "AskUserQuestion の解析は Claude Code 専用です（codex）。C-c C-t のキー透過モードを使ってください"))
    ;; 文面が無い能力を持たない、ということが無いように
    (dolist (cap '(number-reply compact clear slash-completion askq))
      (should (alist-get cap zellij-send--capability-errors)))))

(ert-deftest zellij-send-test-agents-fourth ()
  "4 体目は `zellij-send-agents' に 1 行足すだけで使える。"
  (let ((zellij-send-agents (append zellij-send-agents
                                    '(("mycli" :prompt-marker "[»]"
                                       :progress-file "MYCLI.md"
                                       :capabilities (clear))))))
    (with-temp-buffer
      (setq-local zellij-send--command "/opt/bin/mycli --flag")
      (should (equal (zellij-send--agent-name) "mycli"))
      (should (zellij-send--confirmed-capable-p 'clear))
      (should-not (zellij-send--confirmed-capable-p 'compact))
      (should (equal (zellij-send--progress-file) "MYCLI.md"))
      (should (equal (zellij-send--prompt-marker) "[»]"))
      (should (member "mycli" (zellij-send--agent-names))))
    ;; インタプリタ経由の起動でも名前を拾う
    (should (equal (zellij-send--command-name "node /usr/lib/mycli") "mycli"))))

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

(ert-deftest zellij-send-test-send-preserves-inflight-edits ()
  (dolist (reply '(nil t))
    (dolist (edit '(nil t))
      (dolist (ok '(nil t))
        (let ((buf (generate-new-buffer " *zjs-send-test*")) callback
              (main (generate-new-buffer " *zjs-send-main*"))
              (zellij-send--history-table (make-hash-table :test #'equal)))
          (unwind-protect
              (cl-letf (((symbol-function 'zellij-send--send)
                         (lambda (_session _text cb) (setq callback cb))))
                (with-current-buffer main
                  (setq-local zellij-send--session "test00"))
                (with-current-buffer buf
                  (setq-local zellij-send--session "test00")
                  (setq-local zellij-send--reply-main-buffer main)
                  (insert "送信本文")
                  (if reply (zellij-send--reply-send) (zellij-send-send))
                  (when edit (insert "追記")))
                ;; 実際の非同期コールバック同様、別バッファから完了させる。
                (with-temp-buffer (funcall callback ok))
                (if (and reply ok (not edit))
                    (should-not (buffer-live-p buf))
                  (should (buffer-live-p buf))
                  (with-current-buffer buf
                    (should (equal (buffer-string)
                                   (cond (edit "送信本文追記")
                                         (ok "") (t "送信本文"))))))
                (should (equal (zellij-send-history "test00")
                               (and ok '("送信本文")))))
            (when (buffer-live-p buf) (kill-buffer buf))
            (when (buffer-live-p main) (kill-buffer main))))))))

(ert-deftest zellij-send-test-reply-reads-pane-from-main ()
  "返信は送る時点の元の黒板の pane-id で送る。元の黒板が無ければ送らない。"
  (let ((main (generate-new-buffer " *zjs-reply-main*"))
        (reply nil)
        (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'zellij-send--send)
                   (lambda (session _text _cb)
                     (push (cons session (zellij-send--pane-args)) sent)))
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (with-current-buffer main
            (setq-local zellij-send--session "proj00")
            (setq-local zellij-send--pane-id "terminal_1")
            (zellij-send-reply)
            (setq reply (get-buffer "*zellij-reply-proj00*"))
            ;; 返信バッファを開いた後に、元の黒板でペインが検出し直された
            (setq-local zellij-send--pane-id "terminal_5"))
          (with-current-buffer reply
            (should-not (local-variable-p 'zellij-send--pane-id))
            (insert "返信")
            (zellij-send--reply-send))
          (should (equal (car sent)
                         '("proj00" "--pane-id" "terminal_5")))
          ;; 元の黒板を閉じたら送らない（本文は残す）
          (kill-buffer main)
          (with-current-buffer reply
            (should-error (zellij-send--reply-send) :type 'user-error)
            (should (equal (buffer-string) "返信")))
          (should (= (length sent) 1)))
      (when (buffer-live-p main) (kill-buffer main))
      (when (buffer-live-p reply) (kill-buffer reply)))))

;;; transcript の候補行

(ert-deftest zellij-send-test-transcript-ai-title ()
  "ai-title 行から題名を取り、末尾に近いものを選ぶ。"
  (let ((text (concat
               "{\"type\":\"user\",\"message\":{\"content\":\"やあ\"}}\n"
               "{\"type\":\"ai-title\",\"aiTitle\":\"古い題名\"}\n"
               "{\"type\":\"assistant\"}\n"
               "{\"type\":\"ai-title\",\"aiTitle\":\"新しい題名\"}\n")))
    (should (equal (zellij-send--transcript-ai-title text) "新しい題名")))
  ;; 壊れた行は読み飛ばして、その手前の ai-title を使う
  (should (equal (zellij-send--transcript-ai-title
                  (concat "{\"type\":\"ai-title\",\"aiTitle\":\"生き残り\"}\n"
                          "{\"type\":\"ai-title\",\"aiTit"))
                 "生き残り"))
  (should-not (zellij-send--transcript-ai-title
               "{\"type\":\"assistant\",\"message\":{}}\n")))

(ert-deftest zellij-send-test-transcript-first-user ()
  "ai-title が無いときの代わりに最初の発言を 1 行で返す。"
  (should (equal (zellij-send--transcript-first-user
                  "{\"type\":\"user\",\"message\":{\"content\":\"一行目\\n二行目\"}}\n")
                 "一行目 二行目"))
  ;; スラッシュコマンドの注意書きは毎回同じ英文なので題名にしない
  (should (equal (zellij-send--transcript-first-user
                  (concat "{\"type\":\"user\",\"message\":"
                          "{\"content\":\"<local-command-caveat>Caveat: ...</local-command-caveat>\"}}\n"
                          "{\"type\":\"user\",\"message\":"
                          "{\"content\":\"<command-name>/model</command-name>\"}}\n"))
                 "/model"))
  ;; ツールの結果は発言ではない
  (should (equal (zellij-send--transcript-first-user
                  (concat "{\"type\":\"user\",\"message\":{\"content\":"
                          "[{\"type\":\"tool_result\",\"content\":\"出力\"}]}}\n"
                          "{\"type\":\"user\",\"message\":{\"content\":\"本題\"}}\n"))
                 "本題"))
  (should-not (zellij-send--transcript-first-user "{\"type\":\"assistant\"}\n")))

(ert-deftest zellij-send-test-transcript-label ()
  "候補行は 日時・サイズ・題名 の順で、長い題名は切り詰める。"
  (let ((line (zellij-send--transcript-label
               "会話履歴の選択肢が読めない"
               (encode-time 0 33 17 9 9 2026) 380000)))
    (should (string-prefix-p "09-09 17:33" line))
    (should (string-match-p "371 KB" line))
    (should (string-suffix-p "会話履歴の選択肢が読めない" line)))
  (should (string-suffix-p "…" (zellij-send--transcript-label
                                (make-string 200 ?a) (current-time) 10))))

(ert-deftest zellij-send-test-transcript-candidates ()
  "新しい順に並び、題名が同じものには UUID が付く。"
  (let* ((root (make-temp-file "zjs-cand-" t))
         (old-file (expand-file-name "aaaa-old.jsonl" root))
         (new-file (expand-file-name "bbbb-new.jsonl" root)))
    (unwind-protect
        (progn
          (write-region "{\"type\":\"ai-title\",\"aiTitle\":\"同じ題名\"}\n"
                        nil old-file nil 'silent)
          (write-region "{\"type\":\"ai-title\",\"aiTitle\":\"同じ題名\"}\n"
                        nil new-file nil 'silent)
          (set-file-times old-file (encode-time 0 0 12 1 9 2026))
          (set-file-times new-file (encode-time 0 0 12 8 9 2026))
          (let ((cands (zellij-send--transcript-candidates
                        (list old-file new-file))))
            (should (equal (mapcar #'cdr cands) (list new-file old-file)))
            (should (string-match-p "同じ題名" (car (nth 0 cands)))))
          ;; 日時・サイズ・題名がすべて同じなら UUID（ここではファイル名）が付く
          (set-file-times old-file (encode-time 0 0 12 8 9 2026))
          (let ((cands (zellij-send--transcript-candidates
                        (list old-file new-file))))
            (should-not (equal (car (nth 0 cands)) (car (nth 1 cands))))
            (should (string-match-p "\\[" (car (nth 1 cands))))))
      (delete-directory root t))))

(ert-deftest zellij-send-test-transcript-title-fallback ()
  "ai-title が無ければ最初の発言、それも無ければ (題名なし)。"
  (let* ((root (make-temp-file "zjs-title-" t))
         (titled (expand-file-name "a.jsonl" root))
         (plain (expand-file-name "b.jsonl" root))
         (empty (expand-file-name "c.jsonl" root)))
    (unwind-protect
        (progn
          (write-region (concat "{\"type\":\"user\",\"message\":{\"content\":\"発言\"}}\n"
                                "{\"type\":\"ai-title\",\"aiTitle\":\"題名\"}\n")
                        nil titled nil 'silent)
          (write-region "{\"type\":\"user\",\"message\":{\"content\":\"発言だけ\"}}\n"
                        nil plain nil 'silent)
          (write-region "" nil empty nil 'silent)
          (should (equal (zellij-send--transcript-title titled) "題名"))
          (should (equal (zellij-send--transcript-title plain) "発言だけ"))
          (should (equal (zellij-send--transcript-title empty) "(題名なし)")))
      (delete-directory root t))))

(ert-deftest zellij-send-test-transcript-session-binding ()
  (let* ((root (make-temp-file "zjs-transcripts-" t))
         (zellij-send-transcript-dir root)
         (proj (expand-file-name (zellij-send--transcript-slug "/project") root))
         (first (expand-file-name "session-a.jsonl" proj))
         (second (expand-file-name "session-b.jsonl" proj))
         (choice first) (prompts 0))
    (unwind-protect
        (progn
          (make-directory proj)
          (write-region "" nil first nil 'silent)
          (write-region "" nil second nil 'silent)
          (cl-letf (((symbol-function 'completing-read)
                     ;; 候補は「日時 サイズ 題名」の行なので、パスから引き直す
                     (lambda (&rest _)
                       (cl-incf prompts)
                       (car (rassoc choice
                                    (zellij-send--transcript-candidates
                                     (list first second)))))))
            (with-temp-buffer
              (setq-local zellij-send--session "project00")
              (should (equal (zellij-send--transcript-file "/project") first))
              (setq choice second)
              (should (equal (zellij-send--transcript-file "/project") first))
              (should (= prompts 1))
              (with-temp-buffer
                (setq-local zellij-send--session "project01")
                (should (equal (zellij-send--transcript-file "/project") second)))
              (should (equal (zellij-send--transcript-file "/project") first))
              (should (equal (zellij-send--transcript-file "/project" t) second))
              (delete-file second)
              (should-error (zellij-send--transcript-file "/project")
                            :type 'user-error))))
      (delete-directory root t))))

;;; 選択中の更新保留（--update-buffer / --pending-*）

(defmacro zellij-send-test--with-board (&rest body)
  "選択ウィンドウに黒板バッファを出した状態で BODY を実行する。
`transient-mark-mode' は batch では無効なので有効にして束縛する。"
  (declare (indent 0) (debug t))
  `(let ((buf (generate-new-buffer "*ai-test00*"))
         (transient-mark-mode t))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buf)
           (zellij-send-mode)
           (setq-local zellij-send--session "test00")
           ,@body)
       (kill-buffer buf))))

(defun zellij-send-test--run-timers ()
  "`run-at-time' 0 で予約した処理を走らせる。"
  (accept-process-output nil 0.05))

(ert-deftest zellij-send-test-update-defers-while-selecting ()
  "選択中は書き換えず、最新の内容だけを保留する。
旧実装は `erase-buffer' でマークが point-min に潰れていた。"
  (zellij-send-test--with-board
    (zellij-send--update-buffer "line one\nline two")
    (goto-char 6)
    (push-mark (point) t t)
    (forward-char 3)
    (should (region-active-p))
    (zellij-send--update-buffer "B")
    (should (equal (buffer-string) "line one\nline two"))
    (should (= (mark) 6))
    (should (= (point) 9))
    (should (equal zellij-send--pending-content "B"))
    ;; さらに届いたら最新に差し替える
    (zellij-send--update-buffer "C")
    (should (equal zellij-send--pending-content "C"))
    ;; 画面と同じ内容に戻ったら保留は無い
    (zellij-send--update-buffer "line one\nline two")
    (should-not zellij-send--pending-content)))

(ert-deftest zellij-send-test-update-follows-end ()
  "末尾にいたら更新後も末尾を追い、最下段を窓の下端に合わせる。
送信成功で黒板が空になった直後もこれに当たる。旧実装は point 1 に留まり、
回答が出る下端が見えなかった。"
  (zellij-send-test--with-board
    (let ((screen (lambda (n)
                    (mapconcat (lambda (i) (format "line %d" i))
                               (number-sequence 1 n) "\n")))
          ;; batch では再描画が走らず `pos-visible-in-window-p' が使えないので、
          ;; 開始位置が「末尾から窓の高さぶん上の行頭」かで確かめる
          (bottom-start (lambda ()
                          (save-excursion
                            (goto-char (point-max))
                            (forward-line (- 1 (window-body-height)))
                            (point)))))
      ;; 空の黒板（送信直後）は末尾にいる扱い
      (zellij-send--update-buffer (funcall screen 100))
      (should (= (point) (point-max)))
      (should (= (window-point) (point-max)))
      (should (> (window-start) 1))
      (should (= (window-start) (funcall bottom-start)))
      ;; 伸びても末尾を追う
      (zellij-send--update-buffer (funcall screen 120))
      (should (= (point) (point-max)))
      (should (= (window-start) (funcall bottom-start)))
      ;; 上へ動いたら追わず、位置を保つ
      (goto-char 10)
      (zellij-send--update-buffer (funcall screen 130))
      (should (= (point) 10)))))

(ert-deftest zellij-send-test-pending-resumes-on-deactivate ()
  "選択を解くと保留していた最新の内容を反映する。"
  (zellij-send-test--with-board
    (zellij-send--update-buffer "A")
    (push-mark (point-min) t t)
    (zellij-send--update-buffer "B")
    (zellij-send--update-buffer "C")
    (should (equal (buffer-string) "A"))
    (deactivate-mark)
    (zellij-send-test--run-timers)
    (should (equal (buffer-string) "C"))
    (should-not zellij-send--pending-content)
    (should-not (buffer-modified-p))))

(ert-deftest zellij-send-test-pending-dropped-after-edit-or-clear ()
  "保留中に入力・クリアされたら、選択を解いても古い画面を復活させない。"
  (zellij-send-test--with-board
    (zellij-send--update-buffer "A")
    (push-mark (point-min) t t)
    (zellij-send--update-buffer "B")
    (goto-char (point-max))
    (insert "draft")
    (deactivate-mark)
    (zellij-send-test--run-timers)
    (should (equal (buffer-string) "Adraft"))
    (should-not zellij-send--pending-content))
  (zellij-send-test--with-board
    (zellij-send--update-buffer "A")
    (push-mark (point-min) t t)
    (zellij-send--update-buffer "B")
    (zellij-send-clear-buffer)
    (should-not zellij-send--pending-content)
    ;; クリア後に user-cleared が解除されても（送信成功時など）復活しない
    (setq zellij-send--user-cleared nil)
    (deactivate-mark)
    (zellij-send-test--run-timers)
    (should (equal (buffer-string) ""))))

(ert-deftest zellij-send-test-pending-per-buffer ()
  "保留はバッファごと。選択ウィンドウに出ていないバッファは保留しない。"
  (zellij-send-test--with-board
    (let ((other (generate-new-buffer "*ai-test01*")))
      (unwind-protect
          (progn
            (with-current-buffer other
              (zellij-send-mode)
              (zellij-send--update-buffer "X")
              ;; region を残したまま別ウィンドウへ移った状態
              (push-mark (point-min) t t)
              (zellij-send--update-buffer "Y")
              (should (equal (buffer-string) "Y"))
              (should-not zellij-send--pending-content))
            (zellij-send--update-buffer "A")
            (push-mark (point-min) t t)
            (zellij-send--update-buffer "B")
            (should (equal zellij-send--pending-content "B"))
            (should-not (buffer-local-value 'zellij-send--pending-content other)))
        (kill-buffer other)))))

(ert-deftest zellij-send-test-update-without-transient-mark-mode ()
  "`transient-mark-mode' が無効なら保留しない（`mark-active' は真のまま残るため）。
マークの位置は書き換えの前後で保つ。"
  (zellij-send-test--with-board
    (zellij-send--update-buffer "line one\nline two")
    (let ((transient-mark-mode nil))
      (push-mark 6 t t)
      (should mark-active)
      (zellij-send--update-buffer "line ONE\nline two")
      (should (equal (buffer-string) "line ONE\nline two"))
      (should (= (mark t) 6))
      (should-not zellij-send--pending-content))))

(ert-deftest zellij-send-test-subscribe-refreshes-stale-pending ()
  "subscribe で A → 保留 B → A と戻ったら、保留の B を捨てる。
画面と同じ内容は書き換えを省く分岐があり、そこで B が残っていた。"
  (zellij-send-test--with-board
    (zellij-send--subscribe-handle-line "{\"viewport\":[\"A\"]}")
    (should (equal (buffer-string) "A"))
    (push-mark (point-min) t t)
    (zellij-send--subscribe-handle-line "{\"viewport\":[\"B\"]}")
    (should (equal zellij-send--pending-content "B"))
    (zellij-send--subscribe-handle-line "{\"viewport\":[\"A\"]}")
    (should-not zellij-send--pending-content)
    (deactivate-mark)
    (zellij-send-test--run-timers)
    (should (equal (buffer-string) "A"))))

(ert-deftest zellij-send-test-subscribe-line-whitespace ()
  "前後に空白がある行も読み、空白だけの行では黒板を消さない。
`string-trim' をやめた（空白の多い行で 70 ms かかった）ので、その代わりの判定を確かめる。"
  (zellij-send-test--with-board
    (zellij-send--subscribe-handle-line "  {\"viewport\":[\"A   \"]} \r")
    (should (equal (buffer-string) "A"))
    (zellij-send--subscribe-handle-line " \t\r")
    (should (equal (buffer-string) "A"))))

;;; 黒板の桁揃え

(ert-deftest zellij-send-test-grid-root-char-width-table ()
  "言語環境が上に積んだ表をたどって、一番下の親を返す。"
  ;; batch の `char-width-table' 自体が親を持つことがあるので、表は自前で積む
  (let* ((root (make-char-table nil))
         (jis (make-char-table nil))
         (ambiguous (make-char-table nil)))
    (set-char-table-parent jis root)
    (set-char-table-parent ambiguous jis)
    (let ((char-width-table ambiguous))
      (should (eq (zellij-send--root-char-width-table) root)))))

(ert-deftest zellij-send-test-grid-board-uses-unicode-width ()
  "黒板バッファの中だけ曖昧幅を 1 桁で数える。全角は 2 桁のまま。
日本語環境では `─' が 2 桁になり、zellij の画面と桁がずれていた。"
  (let ((saved char-width-table)
        (wide (make-char-table nil)))
    (set-char-table-range wide ?─ 2)
    (set-char-table-parent wide char-width-table)
    (unwind-protect
        (progn
          (setq char-width-table wide)
          (zellij-send-test--with-board
            (should (= (char-width ?─) 1))
            (should (= (char-width ?あ) 2)))
          ;; 他のバッファは言語環境の幅のまま
          (with-temp-buffer
            (should (= (char-width ?─) 2))))
      (setq char-width-table saved))))

(ert-deftest zellij-send-test-grid-symbols ()
  "画面から対象の記号だけを、出てきた順に重複なしで拾う。
ASCII と日本語は拾わない（全部測ると初回に 0.64 秒固まった）。"
  (should (equal (zellij-send--grid-symbols
                  "╭──╮\n❯ 1. 日本語 ⏺ ⎿ ※…\n  ✻ Thinking")
                 '(?╭ ?─ ?╮ ?❯ ?⏺ ?⎿ ?※ ?… ?✻)))
  (should-not (zellij-send--grid-symbols "plain ascii と日本語")))

(ert-deftest zellij-send-test-grid-pick-face ()
  "字形の無い字体はすぐ飛ばし、1 桁に収まる最大の倍率を選ぶ。"
  (let* ((calls 0)
         (measure (lambda (_char family height)
                    (pcase family
                      ("NoGlyph" (cl-incf calls) nil)
                      ("Wide" 14)
                      ("Menlo" (round (* 8 height)))))))
    (should (equal (zellij-send--grid-pick-face ?─ 7 '("NoGlyph" "Menlo") measure)
                   '("Menlo" . 0.9)))
    (should (= calls 1))
    (should-not (zellij-send--grid-pick-face ?─ 7 '("NoGlyph" "Wide") measure))))

(ert-deftest zellij-send-test-grid-truncates-only-screen ()
  "折り返しを切った黒板でも、書き始めたら折り返しに戻す。"
  (let ((zellij-send-wrap-screen nil))
    (zellij-send-test--with-board
      (zellij-send--update-buffer "─────")
      (should truncate-lines)
      (goto-char (point-max))
      (insert "下書き")
      (should-not truncate-lines)
      (set-buffer-modified-p nil)
      (zellij-send--update-buffer "─────")
      (should truncate-lines))))

(ert-deftest zellij-send-test-grid-toggle-wrap ()
  "既定では画面も折り返す。切り替えは受信しても戻らない。"
  (zellij-send-test--with-board
    (zellij-send--update-buffer "─────")
    (should-not truncate-lines)
    (zellij-send-toggle-wrap)
    (should truncate-lines)
    (zellij-send--update-buffer "─────┐")
    (should truncate-lines)
    (zellij-send-toggle-wrap)
    (should-not truncate-lines)
    (zellij-send--update-buffer "─────")
    (should-not truncate-lines)))

;;; 黒板・受信の不具合の回帰テスト

(ert-deftest zellij-send-test-op-token ()
  "期限切れの古い操作が後から終わっても、新しい操作の印を下ろさない。"
  (with-temp-buffer
    (let* ((buf (current-buffer))
           (old (zellij-send--op-begin buf 'slash-collect)))
      (should old)
      ;; 走っている間は別の操作を始めない
      (should-not (zellij-send--op-begin buf 'askq))
      ;; 古い操作を期限切れにして、新しい操作を始める
      (setf (zellij-send-op-deadline old) (- (float-time) 1))
      (should-not (zellij-send--op-current))
      (let ((new (zellij-send--op-begin buf 'slash-collect)))
        (should new)
        (zellij-send--op-end old)
        (should (eq (zellij-send--op-current) new))
        (zellij-send--op-end new)
        (should-not (zellij-send--op-current))))))

(ert-deftest zellij-send-test-op-busy-refuses ()
  "先読みの取得中に C-c C-s を押すと、従来どおり「取得中です」と断る。"
  (zellij-send-test--with-draft-board nil
    (zellij-send--op-begin (current-buffer) 'slash-collect :silent t)
    (should (equal (cadr (should-error (zellij-send-slash-command)
                                       :type 'user-error))
                   "スラッシュコマンド一覧を取得中です。数秒後にもう一度どうぞ"))
    ;; 取り合う相手が回答でも同じく断る（入力欄は 1 つ）
    (should-error (zellij-send-answer-question) :type 'user-error)))

(ert-deftest zellij-send-test-op-abort ()
  "止めたら、待っていたタイマーも、遅れて返った画面の続きも動かない。
入力欄は打ちかけのときだけ Ctrl+U で片付ける。"
  (with-temp-buffer
    (setq-local zellij-send--session "proj00")
    (let ((buf (current-buffer)) keys fired dump-cb)
      (cl-letf (((symbol-function 'zellij-send--send-keys)
                 (lambda (_session bytes &optional _cb) (push bytes keys)))
                ((symbol-function 'zellij-send--dump-screen-async)
                 (lambda (_session cb &optional _full) (setq dump-cb cb))))
        ;; 打っていない操作を止めても Ctrl+U は送らない
        (let ((op (zellij-send--op-begin buf 'slash-arg)))
          (zellij-send--op-later op 60 (lambda () (setq fired t)))
          (should (timerp (zellij-send-op-timer op)))
          (should (zellij-send--op-abort buf))
          (should-not (zellij-send-op-timer op))
          (should-not keys)
          (should-not (zellij-send--op-current)))
        ;; 打ちかけなら片付ける。走っていた dump の続きは呼ばない
        (let ((op (zellij-send--op-begin buf 'slash-collect)))
          (zellij-send--op-put op :typed t)
          (zellij-send--op-dump op (lambda (_screen) (setq fired t)))
          (zellij-send--op-abort buf)
          (should (equal keys '((21))))
          (funcall dump-cb "遅れて返った画面")
          ;; 止めた操作には、もう何も送らない
          (zellij-send--op-keys op '(13) #'ignore)
          (should (equal keys '((21)))))
        (should-not fired)
        (should-not (zellij-send--op-abort buf))))))

(ert-deftest zellij-send-test-history-next-keeps-draft ()
  "履歴を辿っていないときの M-n は下書きを消さない。
かつては退避していない下書きを空文字で「復帰」して消していた。"
  (let ((zellij-send--history-table (make-hash-table :test 'equal)))
    (with-temp-buffer
      (setq-local zellij-send--session "test00")
      (zellij-send--history-add "test00" "送った文")
      (insert "書きかけ")
      (should-error (zellij-send-history-next) :type 'user-error)
      (should (equal (buffer-string) "書きかけ"))
      ;; 辿ってから戻れば下書きに復帰する
      (zellij-send-history-prev)
      (should (equal (buffer-string) "送った文"))
      (zellij-send-history-next)
      (should (equal (buffer-string) "書きかけ")))))

(ert-deftest zellij-send-test-subscribe-ignores-non-screen-events ()
  "`viewport' の無いイベントや壊れた行で黒板を空にしない。"
  (with-temp-buffer
    (insert "いまの画面")
    (set-buffer-modified-p nil)
    (zellij-send--subscribe-handle-line "{\"event\":\"other\"}")
    (zellij-send--subscribe-handle-line "{\"event\":\"pane_update\",\"viewp")
    (should (equal (buffer-string) "いまの画面"))
    (zellij-send--subscribe-handle-line
     "{\"event\":\"pane_update\",\"viewport\":[\"新しい画面   \"]}")
    (should (equal (buffer-string) "新しい画面"))))

(ert-deftest zellij-send-test-keys-mode-restores-read-only ()
  "キー透過モードを重ねて有効にしても、抜けたら元の read-only に戻る。"
  (with-temp-buffer
    (setq-local zellij-send--session "test00")
    (should-not buffer-read-only)
    (zellij-send-keys-mode 1)
    (zellij-send-keys-mode 1)
    (should buffer-read-only)
    (zellij-send-keys-mode -1)
    (should-not buffer-read-only)
    ;; 元から read-only なら抜けても read-only のまま
    (setq buffer-read-only t)
    (zellij-send-keys-mode 1)
    (zellij-send-keys-mode -1)
    (should buffer-read-only)))

(ert-deftest zellij-send-test-pane-table ()
  "ヘッダとフィールド数の合わない行は表から落とす。"
  (let ((table (zellij-send--pane-table
                "PANE_ID  TYPE  TITLE\nterminal_1  terminal  claude\nterminal_2  terminal  a  b\n")))
    (should (equal (car table) '("PANE_ID" "TYPE" "TITLE")))
    (should (equal (cdr table) '(("terminal_1" "terminal" "claude")))))
  (should (equal (zellij-send--pane-table "") '(nil))))

;;; 画面を読む対象（黒板の中身ではなく受け取った画面）

(defmacro zellij-send-test--with-draft-board (screen &rest body)
  "下書き入りの黒板で BODY を実行する。最後に受け取った画面は SCREEN。"
  (declare (indent 1))
  `(with-temp-buffer
     (setq-local zellij-send--session "test00")
     (setq-local zellij-send--command "claude")
     (setq-local zellij-send--last-content ,screen)
     (insert "書きかけの下書き\n> 1. 引用の箇条書き")
     (set-buffer-modified-p t)
     ,@body))

(ert-deftest zellij-send-test-last-screen ()
  "画面の代わりに下書きを返さない。"
  (with-temp-buffer
    (insert "画面")
    (set-buffer-modified-p nil)
    ;; subscribe を受けていなくても、画面を映している黒板ならその中身
    (should (equal (zellij-send--last-screen) "画面"))
    (set-buffer-modified-p t)
    (should-not (zellij-send--last-screen))
    (setq-local zellij-send--last-content "受け取った画面")
    (should (equal (zellij-send--last-screen) "受け取った画面"))))

(ert-deftest zellij-send-test-answer-question-reads-pane ()
  "下書きがある黒板でも C-c C-q はペインの画面の質問に答える。"
  (let (asked dumped)
    (zellij-send-test--with-draft-board nil
      (cl-letf (((symbol-function 'zellij-send--dump-screen-async)
                 (lambda (_session cb &optional _full)
                   (setq dumped t)
                   (funcall cb zellij-send-test--askq-single)))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args) (apply fn args)))
                ((symbol-function 'zellij-send--askq-answer)
                 (lambda (_buf q) (setq asked q))))
        (zellij-send-answer-question)
        (should dumped)
        (should (equal (plist-get asked :question) "好きな色はどれですか？"))
        ;; 下書きはそのまま
        (should (string-prefix-p "書きかけの下書き" (buffer-string)))))))

(ert-deftest zellij-send-test-askq-continue-reads-pane ()
  "回答の続きもペインから取り直す。下書きを画面と読んで終わったと思わない。"
  (let (asked)
    (zellij-send-test--with-draft-board nil
      (cl-letf (((symbol-function 'zellij-send--dump-screen-async)
                 (lambda (_session cb &optional _full)
                   (funcall cb zellij-send-test--askq-review)))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args) (apply fn args)))
                ((symbol-function 'zellij-send--askq-answer)
                 (lambda (_op q) (setq asked q))))
        (zellij-send--askq-continue
         (zellij-send--op-begin (current-buffer) 'askq
                                :state (list :repeat 0 :rounds 0)))
        (should (eq (plist-get asked :kind) 'review))))))

(ert-deftest zellij-send-test-askq-focus-reads-pane ()
  "カーソル合わせはペインの画面で現在位置を読む。"
  (let (keys result)
    (zellij-send-test--with-draft-board nil
      (cl-letf (((symbol-function 'zellij-send--dump-screen-async)
                 (lambda (_session cb &optional _full)
                   ;; 1 回目は 1 番、送った後は 4 番にカーソルがある画面
                   (funcall cb (if keys
                                   (replace-regexp-in-string
                                    "❯ 1\\." "  1."
                                    (replace-regexp-in-string
                                     "  4\\. Type" "❯ 4. Type"
                                     zellij-send-test--askq-single))
                                 zellij-send-test--askq-single))))
                ((symbol-function 'zellij-send--askq-send-keys)
                 (lambda (_op seq cb) (push seq keys) (funcall cb t)))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args) (apply fn args))))
        (zellij-send--askq-focus (zellij-send--op-begin (current-buffer) 'askq) 4
                                 (lambda (ok) (setq result ok)))
        (should (eq result t))
        ;; 下へ 1 回送ってから、画面で 4 番に着いたことを確かめた
        (should (equal keys '(((27 91 66)))))))))

(ert-deftest zellij-send-test-list-sessions-failed-is-not-empty ()
  "セッション一覧の取得に失敗しても、0 件と読んで黒板を消さない。"
  (let ((buf (generate-new-buffer " *zjs-quit*")) polled)
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (&rest _) (setq polled t))))
          (dolist (result '((:failed "タイムアウト") (:ok ("proj00"))))
            (setq polled nil)
            (cl-letf (((symbol-function 'zellij-send--list-sessions-async)
                       (lambda (cb) (funcall cb result))))
              (zellij-send--await-agent-exit "proj00" nil buf (+ (float-time) 60)))
            (should (buffer-live-p buf))
            (should polled))
          ;; 一覧に無いと確かめられたときだけ消す
          (cl-letf (((symbol-function 'zellij-send--list-sessions-async)
                     (lambda (cb) (funcall cb '(:ok ("other00"))))))
            (zellij-send--await-agent-exit "proj00" nil buf (+ (float-time) 60)))
          (should-not (buffer-live-p buf)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest zellij-send-test-sync-sessions-stale ()
  "セッションの検出は、期限切れの印が残っていても止まらない。"
  (let ((zellij-send--scanning (- (float-time) 3600))
        (zellij-send-prune-gone nil)
        called)
    (cl-letf (((symbol-function 'zellij-send-list-sessions)
               (lambda (cb) (setq called t) (funcall cb '(:ok nil)))))
      (zellij-send-sync-sessions)
      (should called)
      (should-not zellij-send--scanning)
      ;; 走っている間は多重に起動しない
      (setq called nil zellij-send--scanning (float-time))
      (zellij-send-sync-sessions)
      (should-not called))))

(ert-deftest zellij-send-test-sync-sessions-connect ()
  "未接続のセッションへの接続は、自動接続が切られていても手動なら行う。"
  (let ((zellij-send--scanning nil)
        (zellij-send-prune-gone nil)
        attached)
    (cl-letf (((symbol-function 'zellij-send-list-sessions)
               (lambda (cb) (funcall cb '(:ok ("zjs-new00")))))
              ((symbol-function 'zellij-send-attach-session-async)
               (lambda (session &optional _cb) (push session attached)))
              ((symbol-function 'message) #'ignore))
      (let ((zellij-send-auto-connect nil))
        (zellij-send-sync-sessions)
        (should-not attached)
        (zellij-send-sync-sessions t)
        (should (equal attached '("zjs-new00"))))
      (setq attached nil)
      (let ((zellij-send-auto-connect t))
        (zellij-send-sync-sessions)
        (should (equal attached '("zjs-new00")))))))

(ert-deftest zellij-send-test-prune-gone ()
  "消えたセッションの黒板を片付けて履歴を捨てる。作ったばかりの黒板と編集中の黒板は残す。"
  (let ((zellij-send--history-table (make-hash-table :test #'equal))
        (old (generate-new-buffer " *zjs-old*"))
        (young (generate-new-buffer " *zjs-young*"))
        (draft (generate-new-buffer " *zjs-draft*")))
    (unwind-protect
        (cl-letf (((symbol-function 'message) #'ignore))
          (dolist (spec `((,old "zjs-old00" 3600) (,young "zjs-young00" 1)
                          (,draft "zjs-draft00" 3600)))
            (with-current-buffer (nth 0 spec)
              (zellij-send-mode)
              (setq zellij-send--session (nth 1 spec)
                    zellij-send--created-at (- (float-time) (nth 2 spec)))))
          (with-current-buffer draft (insert "下書き"))
          (zellij-send--history-add "zjs-old00" "前の送信")
          (should (= (zellij-send--prune-gone '("other00")) 1))
          (should-not (buffer-live-p old))
          (should-not (zellij-send-history "zjs-old00"))
          (should (buffer-live-p young))
          (should (buffer-live-p draft)))
      (dolist (b (list old young draft))
        (when (buffer-live-p b)
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b))))))

(ert-deftest zellij-send-test-session-watch-stops ()
  "監視は黒板も登録したバッファも無くなったら止まる。"
  (let ((zellij-send--session-watch-timer nil)
        (zellij-send--session-watch-owners nil)
        (zellij-send-scan-interval 15.0)
        (owner (generate-new-buffer " *zjs-owner*"))
        synced)
    (unwind-protect
        (cl-letf (((symbol-function 'zellij-send-sessions) (lambda () nil))
                  ((symbol-function 'zellij-send-sync-sessions)
                   (lambda (&optional _) (setq synced t))))
          (zellij-send-start-session-watch owner)
          (should (timerp zellij-send--session-watch-timer))
          ;; 登録したバッファが生きている間は、黒板が 0 個でも続ける
          (zellij-send--session-watch-tick)
          (should synced)
          (should (timerp zellij-send--session-watch-timer))
          (kill-buffer owner)
          (setq synced nil)
          (zellij-send--session-watch-tick)
          (should-not synced)
          (should-not zellij-send--session-watch-timer))
      (zellij-send-stop-session-watch)
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest zellij-send-test-obsolete-watch-variables ()
  "ダッシュボードにあった検出の変数は、本体の新しい名前の別名として効く。"
  (dolist (pair '((zellij-send-dashboard-auto-connect . zellij-send-auto-connect)
                  (zellij-send-dashboard-scan-interval . zellij-send-scan-interval)
                  (zellij-send-dashboard-prune-gone . zellij-send-prune-gone)))
    (should (eq (indirect-variable (car pair)) (cdr pair)))))

(ert-deftest zellij-send-test-dashboard-reads-last-screen ()
  "セッションの状態と状況列は、下書きではなく受け取った画面に追随する。"
  (let ((screen "⏺ 作業しています\n✳ Frobnicating… (12s · esc to interrupt)\n❯ "))
    (zellij-send-test--with-draft-board screen
      (let ((buf (current-buffer)))
        ;; 下書きの `> 1.' は選択肢に見えるが、画面には選択肢が無い。
        ;; 画面のスピナーで作業中
        (should (eq (plist-get (zellij-send-session-state buf) :status)
                    'working))
        (should (plist-get (zellij-send-session-state buf) :editing))
        (should (string-prefix-p "✳ Frobnicating"
                                 (zellij-send-dashboard--tail-line buf)))
        ;; 画面が選択肢待ちに変われば、下書きがあってもそれに追随する
        (setq-local zellij-send--last-content zellij-send-test--askq-single)
        (should (eq (plist-get (zellij-send-session-state buf) :status)
                    'prompt))))))

(ert-deftest zellij-send-test-screen-prompt-p ()
  "選択待ちは AskUserQuestion として読める画面ならそれを正とし、
読めなければ記号の正規表現に落ちる。AskUserQuestion は Claude Code でだけ試す。"
  ;; カーソル記号を外した質問の画面。記号の正規表現では拾えない
  (let ((no-cursor (replace-regexp-in-string
                    "^❯ 1\\." "  1." zellij-send-test--askq-single)))
    (with-temp-buffer
      (setq-local zellij-send--command "claude")
      (should-not (zellij-send--detect-prompt no-cursor))
      (should (zellij-send--screen-prompt-p no-cursor))
      (should (zellij-send--screen-prompt-p zellij-send-test--askq-review))
      (should-not (zellij-send--screen-prompt-p nil))
      (should-not (zellij-send--screen-prompt-p "⏺ 本文だけ")))
    (with-temp-buffer
      (setq-local zellij-send--command "codex")
      (should-not (zellij-send--screen-prompt-p no-cursor))
      (should (zellij-send--screen-prompt-p "› 1. gpt-6-astra (current)")))))

(ert-deftest zellij-send-test-obsolete-dashboard-variables ()
  "ダッシュボードにあった旧名の変数は、本体の新しい名前の別名として効く。"
  (dolist (pair '((zellij-send-dashboard-working-regexp . zellij-send-working-regexp)
                  (zellij-send-dashboard-active-window . zellij-send-active-window)
                  (zellij-send-dashboard-use-hooks . zellij-send-use-hooks)
                  (zellij-send-dashboard-hook-stale . zellij-send-hook-stale)))
    (should (eq (indirect-variable (car pair)) (cdr pair))))
  (let ((zellij-send-hook-stale 30.0))
    (with-suppressed-warnings ((obsolete zellij-send-dashboard-hook-stale))
      (setq zellij-send-dashboard-hook-stale 60.0))
    (should (= zellij-send-hook-stale 60.0))))

;;; スラッシュコマンド一覧の永続化

(defmacro zellij-send-test--with-slash-cache (&rest body)
  "使い捨てのキャッシュ置き場と作業ディレクトリで BODY を実行する。"
  (declare (indent 0))
  `(let* ((root (make-temp-file "zjs-slash" t))
          (zellij-send-slash-cache-directory (expand-file-name "cache/" root))
          (zellij-send--slash-cache-table (make-hash-table :test 'equal))
          (zellij-send-slash-cache-max-age 3600))
     (unwind-protect
         (with-temp-buffer
           (setq default-directory (file-name-as-directory
                                    (expand-file-name "proj" root)))
           (make-directory default-directory t)
           (setq-local zellij-send--command "claude")
           ,@body)
       (delete-directory root t))))

(defun zellij-send-test--write (file text)
  "FILE に TEXT を書く（ディレクトリも作る）。"
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text)))

(ert-deftest zellij-send-test-slash-cache-survives-restart ()
  "保存した一覧は、メモリを捨てた後（＝再起動後）もディスクから読める。"
  (zellij-send-test--with-slash-cache
    (zellij-send--slash-cache-put '(("/clear" . "Clear") ("/ndl" . "国会図書館")))
    (should (file-exists-p (zellij-send--slash-cache-file
                            zellij-send--slash-global-key)))
    ;; 再起動に相当: メモリの表を空にする
    (clrhash zellij-send--slash-cache-table)
    (should (equal (zellij-send--slash-cached)
                   '(("/clear" . "Clear") ("/ndl" . "国会図書館"))))))

(ert-deftest zellij-send-test-slash-cache-invalidation ()
  "古くなった一覧・材料が変わった一覧・形式の版が古い一覧は使わない。
C-u で捨てたものは戻らない。"
  (zellij-send-test--with-slash-cache
    (zellij-send--slash-cache-put '(("/clear" . "Clear")))
    (let* ((key zellij-send--slash-global-key)
           (entry (gethash key zellij-send--slash-cache-table))
           (fp (plist-get entry :fingerprint))
           (time (plist-get entry :time)))
      (should (zellij-send--slash-cache-valid-p entry fp time))
      ;; 期限切れ
      (should-not (zellij-send--slash-cache-valid-p entry fp (+ time 3601)))
      (let ((zellij-send-slash-cache-max-age nil))
        (should (zellij-send--slash-cache-valid-p entry fp (+ time 1e9))))
      ;; 形式の版が古い（`❯' を読めなかった頃の 1 件の一覧など）
      (should-not (zellij-send--slash-cache-valid-p
                   entry (plist-put (copy-sequence fp) :version 1) time))
      ;; 取り直したものは使える。C-u で捨てるとディスクからも消える
      (should (zellij-send--slash-cached))
      (zellij-send--slash-cache-drop)
      (should-not (file-exists-p (zellij-send--slash-cache-file key)))
      (should-not (zellij-send--slash-cached)))))

(ert-deftest zellij-send-test-slash-cache-shared ()
  "一度取った一覧を、別のプロジェクトでも打ち込まずに使う。
プロジェクト自身のコマンドとスキルは、取ったプロジェクトの分を引き、
使うプロジェクトの分をファイルから足す。"
  (zellij-send-test--with-slash-cache
    (let ((a default-directory)
          (b (file-name-as-directory (expand-file-name "../other" default-directory))))
      ;; A にはスキル、B にはコマンドがある
      (zellij-send-test--write (expand-file-name ".claude/skills/a-skill/SKILL.md" a)
                               "---\nname: a-skill\ndescription: >-\n  A の\n  スキル\n---\n本文\n")
      (zellij-send-test--write (expand-file-name ".claude/commands/b-cmd.md" b)
                               "---\ndescription: \"B のコマンド\"\n---\n本文\n")
      (should (equal (zellij-send--slash-project-entries a) '(("/a-skill" . "A の スキル"))))
      ;; A で取った一覧（A のスキルを含む）
      (zellij-send--slash-cache-put '(("/clear" . "Clear") ("/a-skill" . "A の…")
                                      ("/ndl" . "国会図書館")))
      (should (equal (zellij-send--slash-cached)
                     '(("/a-skill" . "A の スキル") ("/clear" . "Clear")
                       ("/ndl" . "国会図書館"))))
      ;; B では A のスキルが消え、B のコマンドが足される
      (let ((default-directory b))
        (should (equal (zellij-send--slash-cached)
                       '(("/b-cmd" . "B のコマンド") ("/clear" . "Clear")
                         ("/ndl" . "国会図書館")))))
      ;; ファイルから決めきれないプロジェクトでは全体用を使わない
      (let ((default-directory b))
        (zellij-send-test--write (expand-file-name ".mcp.json" b) "{}")
        (should-not (zellij-send--slash-simple-project-p b))
        (should-not (zellij-send--slash-cached))
        ;; そこで取った一覧はそのディレクトリだけのもの
        (zellij-send--slash-cache-put '(("/clear" . "Clear") ("/mcp__x__y" . "")))
        (should (equal (zellij-send--slash-cached)
                       '(("/clear" . "Clear") ("/mcp__x__y" . "")))))
      ;; 全体用は B の分に汚されていない
      (should (equal (mapcar #'car (zellij-send--slash-cached))
                     '("/a-skill" "/clear" "/ndl"))))))

(ert-deftest zellij-send-test-slash-simple-project ()
  "ファイルから決めきれないものがあるプロジェクトは、ディレクトリごとに取る。"
  (zellij-send-test--with-slash-cache
    (let ((d default-directory))
      (should (zellij-send--slash-simple-project-p d))
      ;; コマンドのサブディレクトリ（名前の付き方を確かめていない）
      (make-directory (expand-file-name ".claude/commands/sub" d) t)
      (should-not (zellij-send--slash-simple-project-p d))
      (delete-directory (expand-file-name ".claude/commands/sub" d))
      (should (zellij-send--slash-simple-project-p d))
      ;; 空の commands は自分自身なら問題ないが、子から見ると「親にもある」になる
      (delete-directory (expand-file-name ".claude/commands" d))
      ;; プロジェクトの設定でプラグインを有効にしている
      (zellij-send-test--write (expand-file-name ".claude/settings.json" d)
                               "{\"enabledPlugins\": {\"x@y\": true}}")
      (should-not (zellij-send--slash-simple-project-p d))
      (delete-file (expand-file-name ".claude/settings.json" d))
      ;; 親ディレクトリにもスキルがある
      (let ((child (file-name-as-directory (expand-file-name "child" d))))
        (make-directory child t)
        (should (zellij-send--slash-simple-project-p child))
        (make-directory (expand-file-name ".claude/skills/p" d) t)
        (should-not (zellij-send--slash-simple-project-p child))))))

(ert-deftest zellij-send-test-slash-cache-other-dir ()
  "別のディレクトリの保存ファイルを読まない。保存しない設定ならファイルを作らない。"
  (zellij-send-test--with-slash-cache
    (let ((key (zellij-send--slash-cache-key)))
      (zellij-send--slash-cache-write
       key (list :entries '(("/x" . "")) :time (float-time) :fingerprint nil))
      (should (zellij-send--slash-cache-read key))
      (should-not (zellij-send--slash-cache-read "/somewhere/else"))
      ;; 中身の :dir が食い違うファイルは捨てる
      (with-temp-file (zellij-send--slash-cache-file "/somewhere/else")
        (prin1 '(:dir "/another" :entries (("/x" . ""))) (current-buffer)))
      (should-not (zellij-send--slash-cache-read "/somewhere/else")))
    (let ((zellij-send-slash-cache-directory nil))
      (should-not (zellij-send--slash-cache-file "/a"))
      (zellij-send--slash-cache-put '(("/clear" . "")))
      (should (equal (zellij-send--slash-cached) '(("/clear" . "")))))))

;;; 直近の編集を diff で見る

(defun zellij-send-test--jsonl (&rest objs)
  "OBJS（alist）を JSONL の文字列にする。"
  (mapconcat (lambda (o) (json-encode o)) objs "\n"))

(defun zellij-send-test--tool-use (name input)
  "NAME の tool_use を 1 つ持つ assistant 行を返す。"
  `((type . "assistant")
    (message . ((content . [((type . "tool_use") (name . ,name)
                             (input . ,input))])))))

(defconst zellij-send-test--user-says
  '((type . "user") (message . ((content . "直して")))))

(ert-deftest zellij-send-test-transcript-edits ()
  "直近のターンの編集を古い順に返す。ターンに無ければ最後の 1 件。"
  (let ((text (zellij-send-test--jsonl
               (zellij-send-test--tool-use
                "Edit" '((file_path . "/p/a.el") (old_string . "x") (new_string . "y")))
               zellij-send-test--user-says
               (zellij-send-test--tool-use
                "Write" '((file_path . "/p/b.el") (content . "new\n")))
               ;; tool_result はターンの区切りではない
               '((type . "user")
                 (message . ((content . [((type . "tool_result") (content . "ok"))]))))
               (zellij-send-test--tool-use
                "Edit" '((file_path . "/p/c.el") (old_string . "1") (new_string . "2")))
               (zellij-send-test--tool-use "Bash" '((command . "ls"))))))
    (should (equal (mapcar (lambda (e) (plist-get e :file))
                           (zellij-send--transcript-edits text))
                   '("/p/b.el" "/p/c.el"))))
  ;; 最後のターンに編集が無ければ、最後の編集 1 件
  (let ((text (zellij-send-test--jsonl
               (zellij-send-test--tool-use
                "Edit" '((file_path . "/p/a.el") (old_string . "x") (new_string . "y")))
               (zellij-send-test--tool-use
                "Edit" '((file_path . "/p/z.el") (old_string . "x") (new_string . "y")))
               zellij-send-test--user-says)))
    (should (equal (mapcar (lambda (e) (plist-get e :file))
                           (zellij-send--transcript-edits text))
                   '("/p/z.el"))))
  ;; 知らないツール・形の違う入力だけなら対象なし
  (should-not (zellij-send--transcript-edits
               (zellij-send-test--jsonl
                (zellij-send-test--tool-use "NotebookEdit" '((notebook_path . "/p/n")))
                (zellij-send-test--tool-use "Edit" '((file_path . "/p/a.el")))
                (zellij-send-test--tool-use "MultiEdit" '((file_path . "/p/a.el")
                                                          (edits . "壊れた形")))))))

(ert-deftest zellij-send-test-multiedit ()
  "MultiEdit は edits の 1 件ずつを Edit と同じ形にする。"
  (should (equal (zellij-send--tool-use-edits
                  "MultiEdit" '((file_path . "/p/a.el")
                                (edits . (((old_string . "a") (new_string . "b"))
                                          ((old_string . "c") (new_string . "d"))))))
                 '((:name "MultiEdit" :file "/p/a.el" :old "a" :new "b")
                   (:name "MultiEdit" :file "/p/a.el" :old "c" :new "d")))))

(ert-deftest zellij-send-test-edit-diff ()
  "Edit は共通の前後を文脈行にした 1 ハンク、Write は全体の追加になる。"
  (let ((zellij-send-transcript-max-block-lines nil))
    (should (equal (zellij-send--edit-diff
                    '(:name "Edit" :file "/p/src/a.el"
                      :old "(defun f ()\n  1)\n;; end" :new "(defun f ()\n  2)\n;; end")
                    "/p/")
                   (concat "Edit: src/a.el\n"
                           "--- a/src/a.el\n+++ b/src/a.el\n"
                           "@@ -1,3 +1,3 @@\n"
                           " (defun f ()\n"
                           "-  1)\n"
                           "+  2)\n"
                           " ;; end\n")))
    ;; 全部が同じ行でも壊れない
    (should (string-match-p "@@ -1,1 \\+1,1 @@\n same\n\\'"
                            (zellij-send--diff-hunk "same" "same")))
    (should (equal (zellij-send--edit-diff
                    '(:name "Write" :file "/elsewhere/b.txt" :content "一\n二\n")
                    "/p/")
                   (concat "Write: /elsewhere/b.txt（ファイル全体。上書き前の内容は表示できません）\n"
                           "--- /dev/null\n+++ /elsewhere/b.txt\n"
                           "@@ -0,0 +1,2 @@\n+一\n+二\n"))))
  ;; 大きな入力は transcript 表示と同じ方針で切る
  (let ((zellij-send-transcript-max-block-lines 2)
        (zellij-send-transcript-max-line-length 5))
    (let ((d (zellij-send--edit-diff
              '(:name "Write" :file "/p/b" :content "1234567890\n2\n3\n4") "/p/")))
      (should (string-match-p "^\\+12345…（この行はあと 5 文字）$" d))
      (should (string-match-p "^@@ -0,0 \\+1,2 @@$" d))
      (should (string-match-p "^\\\\ 残り 2 行は省略$" d)))))

;;; 出力ログのローテーション

(ert-deftest zellij-send-test-log-choose ()
  "退避したログがあれば知らせ、C-u ではそちらを開く。"
  (should (equal (zellij-send--log-rotated-file "/p/.zellij-send/claude-log.md")
                 "/p/.zellij-send/claude-log.1.md"))
  (let* ((dir (make-temp-file "zjs-log" t))
         (cur (expand-file-name "claude-log.md" dir))
         (old (expand-file-name "claude-log.1.md" dir)))
    (unwind-protect
        (progn
          (should-not (zellij-send--log-choose cur nil))
          (write-region "now" nil cur nil 'silent)
          (should (equal (zellij-send--log-choose cur nil) (cons cur nil)))
          ;; C-u でも、以前のログが無ければ現在のログ
          (should (equal (car (zellij-send--log-choose cur t)) cur))
          (write-region "before" nil old nil 'silent)
          (let ((c (zellij-send--log-choose cur nil)))
            (should (equal (car c) cur))
            (should (string-match-p "claude-log\\.1\\.md" (cdr c))))
          (should (equal (car (zellij-send--log-choose cur t)) old))
          (delete-file cur)
          (should (equal (car (zellij-send--log-choose cur nil)) old)))
      (delete-directory dir t))))

;;; フックから受け取る状態

(ert-deftest zellij-send-test-hook-event-state ()
  "フックのイベントを状態に読み替える。知らないものは nil。"
  (should (eq (zellij-send--hook-event-state "UserPromptSubmit" "") 'working))
  (should (eq (zellij-send--hook-event-state "PreToolUse" "AskUserQuestion") 'waiting))
  (should-not (zellij-send--hook-event-state "PreToolUse" "Bash"))
  (should (eq (zellij-send--hook-event-state "PermissionRequest" "Bash") 'waiting))
  (should (eq (zellij-send--hook-event-state "PostToolUse" "Bash") 'working))
  (should (eq (zellij-send--hook-event-state "Stop" "") 'idle))
  (should (eq (zellij-send--hook-event-state "Notification" "permission_prompt") 'waiting))
  (should (eq (zellij-send--hook-event-state "Notification" "idle_prompt") 'idle))
  (should-not (zellij-send--hook-event-state "Notification" "auth_success"))
  (should-not (zellij-send--hook-event-state "SessionStart" "")))

(ert-deftest zellij-send-test-on-claude-hook ()
  "セッション名とペイン番号で黒板を選ぶ。別のペインからのフックは無視する。"
  (let ((a (generate-new-buffer " *zjs-hook-a*"))
        (b (generate-new-buffer " *zjs-hook-b*")))
    (unwind-protect
        (progn
          (dolist (spec `((,a "proj00") (,b "proj01")))
            (with-current-buffer (car spec)
              (setq major-mode 'zellij-send-mode)
              (setq-local zellij-send--session (cadr spec))
              (setq-local zellij-send--pane-id "terminal_1")))
          (zellij-send--on-claude-hook "proj01" "1" "UserPromptSubmit" "")
          (should-not (buffer-local-value 'zellij-send--hook-state a))
          (should (eq (buffer-local-value 'zellij-send--hook-state b) 'working))
          ;; 同じセッションのシェルのペインから来たものは無視
          (zellij-send--on-claude-hook "proj01" "0" "Stop" "")
          (should (eq (buffer-local-value 'zellij-send--hook-state b) 'working))
          (zellij-send--on-claude-hook "proj01" "1" "Stop" "")
          (should (eq (buffer-local-value 'zellij-send--hook-state b) 'idle))
          ;; 知らないセッション・イベントでもエラーにしない
          (should-not (zellij-send--on-claude-hook "nosuch" "1" "Stop" ""))
          ;; 新しいスクリプトが引数を足しても失敗しない
          (should-not (zellij-send--on-claude-hook "nosuch" "1" "Stop" "" nil "将来の引数"))
          ;; Emacs から中断したら捨てる（中断では Stop が来ない）
          (with-current-buffer b
            (setq-local zellij-send--hook-state 'working)
            (cl-letf (((symbol-function 'zellij-send--send-keys) #'ignore))
              (zellij-send-interrupt))
            (should-not zellij-send--hook-state)))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest zellij-send-test-session-hook-status ()
  "フックがあれば本文を流している間も作業中。無ければ従来どおり画面で判定する。"
  (let ((zellij-send-active-window 6.0)
        (zellij-send-hook-stale 30.0)
        (now (float-time)))
    (with-temp-buffer
      (setq-local zellij-send--session "proj00")
      ;; スピナーの無い本文だけの画面が 10 秒前に変わったきり
      (setq-local zellij-send--last-content "⏺ 長い本文を流している途中")
      (setq-local zellij-send--last-change-time (- now 10))
      (let ((buf (current-buffer)))
        ;; フック未設定: 従来どおり待機
        (should (eq (plist-get (zellij-send-session-state buf)
                               :status)
                    'idle))
        ;; フックが作業中と言っている: 作業中
        (setq-local zellij-send--hook-state 'working)
        (setq-local zellij-send--hook-state-time (- now 12))
        (should (eq (plist-get (zellij-send-session-state buf)
                               :status)
                    'working))
        ;; 使わない設定なら画面だけ
        (let ((zellij-send-use-hooks nil))
          (should-not (zellij-send--hook-status now (- now 10))))
        ;; 中断で Stop が来ず、画面も 40 秒止まっている: 信用しない
        (setq-local zellij-send--hook-state-time (- now 40))
        (should-not (zellij-send--hook-status now (- now 40)))
        ;; 選択待ちは、描き終えた後に画面が変わったら捨てる
        (setq-local zellij-send--hook-state 'waiting)
        (setq-local zellij-send--hook-state-time (- now 20))
        (should (eq (zellij-send--hook-status now (- now 19)) 'prompt))
        (should-not (zellij-send--hook-status now (- now 5)))
        ;; 画面の最終変化（10 秒前）がダイアログを描いた分なら選択待ち
        (setq-local zellij-send--hook-state-time (- now 11))
        (should (eq (plist-get (zellij-send-session-state buf)
                               :status)
                    'prompt))))))

(ert-deftest zellij-send-test-hook-transcript ()
  "状態フックが知らせた transcript を、選んでいなければ聞かずに使う。"
  (let* ((dir (make-temp-file "zjs-tr" t))
         (hooked (expand-file-name "hooked.jsonl" dir))
         (chosen (expand-file-name "chosen.jsonl" dir))
         (buf (generate-new-buffer " *zjs-hook-tr*")))
    (unwind-protect
        (progn
          (write-region "" nil hooked nil 'silent)
          (write-region "" nil chosen nil 'silent)
          (with-current-buffer buf
            (setq major-mode 'zellij-send-mode)
            (setq-local zellij-send--session "proj00"))
          ;; 存在しない・jsonl でないパスは使わない
          (zellij-send--on-claude-hook "proj00" "1" "Stop" "" "/nonexistent.jsonl")
          (zellij-send--on-claude-hook "proj00" "1" "Stop" "" dir)
          (should-not (buffer-local-value 'zellij-send--hook-transcript-path buf))
          ;; 状態に関係ないイベントでも transcript は受け取る
          (zellij-send--on-claude-hook "proj00" "1" "SessionStart" "" hooked)
          (with-current-buffer buf
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) (error "聞いてはいけない"))))
              (should (equal (zellij-send--transcript-file dir) hooked)))
            ;; ユーザーが選んだものはフックより優先
            (setq-local zellij-send--transcript-path chosen)
            (should (equal (zellij-send--transcript-file dir) chosen))))
      (kill-buffer buf)
      (delete-directory dir t))))

;;; ダッシュボードの「完了」

(ert-deftest zellij-send-test-dashboard-done ()
  "見ていない間に作業中から待機に変わったら完了。本体の状態に完了は無い。"
  (let ((zellij-send-dashboard--state (make-hash-table :test #'equal))
        (zellij-send-active-window 6.0)
        (now (float-time)))
    (with-temp-buffer
      (setq-local zellij-send--session "proj00")
      (setq-local zellij-send--command "claude")
      (setq-local zellij-send--last-content
                  "✳ Frobnicating… (12s · esc to interrupt)")
      (setq-local zellij-send--last-change-time (- now 60))
      (let ((buf (current-buffer)))
        (should (eq (plist-get (zellij-send-dashboard--update-state
                                buf (zellij-send-session-state buf))
                               :status)
                    'working))
        (setq-local zellij-send--last-content "⏺ 終わりました")
        (should (eq (plist-get (zellij-send-session-state buf) :status) 'idle))
        (should (eq (plist-get (zellij-send-dashboard--update-state
                                buf (zellij-send-session-state buf))
                               :status)
                    'done))
        ;; 選択待ちは完了より優先する
        (setq-local zellij-send--last-content zellij-send-test--askq-single)
        (should (eq (plist-get (zellij-send-dashboard--update-state
                                buf (zellij-send-session-state buf))
                               :status)
                    'prompt))))))

;;; 単独の小さい修正（2026-10-19）

(ert-deftest zellij-send-test-assert-session ()
  "黒板でなければ user-error。黒板なら何もしない。"
  (with-temp-buffer
    (should-error (zellij-send--assert-session) :type 'user-error)
    (setq-local zellij-send--session "proj00")
    (should-not (zellij-send--assert-session))))

(ert-deftest zellij-send-test-forget-session ()
  "消したセッションの送信履歴を捨て、同じ名前で作り直しても引き継がない。"
  (let ((zellij-send--history-table (make-hash-table :test #'equal)))
    (zellij-send--history-add "proj00" "前のセッションの送信")
    (zellij-send--history-add "proj01" "別のセッション")
    (cl-letf (((symbol-function 'zellij-send--zellij-async)
               (lambda (_args cb) (funcall cb 0))))
      (zellij-send--force-delete-session "proj00" nil "テスト"))
    (should-not (zellij-send-history "proj00"))
    (should (equal (zellij-send-history "proj01") '("別のセッション")))
    ;; 削除に失敗したら残す
    (zellij-send--history-add "proj01" "もう一つ")
    (cl-letf (((symbol-function 'zellij-send--zellij-async)
               (lambda (_args cb) (funcall cb 1))))
      (zellij-send--force-delete-session "proj01" nil "テスト"))
    (should (zellij-send-history "proj01"))))

(ert-deftest zellij-send-test-dashboard-tail-line ()
  "後ろから読んでも、split-string で全行を見ていた頃と同じ行を拾う。"
  (let ((zellij-send-dashboard-tail-width 40))
    (dolist (case `(("" . "")
                    ("一行だけ" . "一行だけ")
                    ("本文\n" . "本文")
                    ("⏺ 本文\n✳ Concocting… (7s · ↓ 92 tokens)\n\n────\n❯ \n────\n  ⏵⏵ auto mode on (shift+tab to cycle)"
                     . "✳ Concocting… (7s · ↓ 92 tokens)")
                    ;; 下から 40 行を超えた所は読まない
                    (,(concat "遠すぎる行\n" (make-string 40 ?\n)) . "")))
      (with-temp-buffer
        (setq-local zellij-send--last-content (car case))
        (should (equal (zellij-send-dashboard--tail-line (current-buffer))
                       (cdr case)))))))

(ert-deftest zellij-send-test-dashboard-line-start ()
  "直前の改行の次の位置を返す。改行が無ければ 0。"
  (should (= (zellij-send-dashboard--line-start "abc" 3) 0))
  (should (= (zellij-send-dashboard--line-start "" 0) 0))
  ;; 先頭が改行
  (should (= (zellij-send-dashboard--line-start "\nabc" 4) 1))
  (should (= (zellij-send-dashboard--line-start "\nabc" 0) 0))
  ;; 末尾が改行（最終行は空）
  (should (= (zellij-send-dashboard--line-start "abc\n" 4) 4))
  (should (= (zellij-send-dashboard--line-start "abc\n" 3) 0))
  (should (= (zellij-send-dashboard--line-start "ab\ncd\nef" 8) 6)))

(ert-deftest zellij-send-test-session-screen-normal-form ()
  "まだ 1 件も受けていない黒板でも、画面は行末の空白を落とした形で返す。"
  (with-temp-buffer
    (insert "表   \n  本文\t\n\n")
    (set-buffer-modified-p nil)
    (should (equal (zellij-send-session-screen (current-buffer)) "表\n  本文"))
    ;; 受け取った画面があればそれをそのまま返す
    (setq-local zellij-send--last-content "受けた画面")
    (should (equal (zellij-send-session-screen (current-buffer)) "受けた画面"))))

(ert-deftest zellij-send-test-dashboard-usage-cache ()
  "使用状況 JSON は mtime が変わったときだけ読み直す。"
  (let* ((file (make-temp-file "zjs-usage" nil ".json"))
         (zellij-send-dashboard-usage-file file)
         (zellij-send-dashboard--usage-cache nil)
         (parsed 0)
         (orig (symbol-function 'json-parse-buffer)))
    (unwind-protect
        (cl-letf (((symbol-function 'json-parse-buffer)
                   (lambda (&rest args) (setq parsed (1+ parsed)) (apply orig args))))
          (with-temp-file file (insert "{\"a\": 1}"))
          (set-file-times file (seconds-to-time 1000000))
          (should (equal (car (zellij-send-dashboard--read-usage)) '((a . 1))))
          (should (equal (car (zellij-send-dashboard--read-usage)) '((a . 1))))
          (should (= parsed 1))
          (with-temp-file file (insert "{\"a\": 2}"))
          (set-file-times file (seconds-to-time 2000000))
          (should (equal (car (zellij-send-dashboard--read-usage)) '((a . 2))))
          (should (= parsed 2)))
      (delete-file file))))

(ert-deftest zellij-send-test-markdown-fallback-check ()
  "text-mode 派生の黒板で markdown-mode が後から使えるなら、印を付けて 1 回だけ知らせる。"
  (let ((zellij-send--markdown-late-warned nil)
        (messages 0))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) (setq messages (1+ messages)))))
      (with-temp-buffer
        (text-mode)
        (if (fboundp 'markdown-mode)
            (progn (zellij-send--markdown-fallback-check)
                   (should (equal mode-name "ZellijSend[text]")))
          (cl-letf (((symbol-function 'markdown-mode) #'ignore))
            (zellij-send--markdown-fallback-check)
            (should (equal mode-name "ZellijSend[text]"))
            (zellij-send--markdown-fallback-check))))
      (should (= messages 1)))))

;;; 選択待ちの判定は画面の末尾だけを読む

(ert-deftest zellij-send-test-screen-tail ()
  "末尾 N 行を切り出す。N 行に満たなければそのまま。"
  (should (equal (zellij-send--screen-tail "a\nb\nc" 2) "b\nc"))
  (should (equal (zellij-send--screen-tail "a\nb\nc" 3) "a\nb\nc"))
  (should (equal (zellij-send--screen-tail "a\nb\nc" 9) "a\nb\nc"))
  (should (equal (zellij-send--screen-tail "a\nb\n" 1) ""))
  (should (equal (zellij-send--screen-tail "" 5) "")))

(ert-deftest zellij-send-test-screen-prompt-p-tail ()
  "選択肢が末尾にあれば拾い、本文に流れた古い選択肢（末尾から遠い）は拾わない。"
  (with-temp-buffer
    (setq-local zellij-send--command "claude")
    (let ((filler (mapconcat (lambda (i) (format "⏺ 本文 %d" i))
                             (number-sequence 1 100) "\n")))
      (should (zellij-send--screen-prompt-p
               (concat filler "\n" zellij-send-test--askq-single)))
      (should-not (zellij-send--screen-prompt-p
                   (concat "❯ 1. 古い選択肢\n  2. もう一つ\n" filler "\n❯ "))))))

;;; ペインの特定のやり直し

(ert-deftest zellij-send-test-detect-pane-retry ()
  "pane-id が取れなければやり直す。上限まで取れなければ nil を渡す。"
  (let ((table (concat "TAB_ID  TAB_POS  TAB_NAME  PANE_ID  TYPE  TITLE  COMMAND  CWD  FOCUSED  FLOATING  EXITED  X  Y  ROWS  COLS\n"
                       "0  0  Tab #1  terminal_1  terminal  agy  agy  /tmp  true  false  false  0  1  498  320\n"))
        (calls 0) result)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat fn &rest args) (apply fn args))))
      ;; 1 回目だけ失敗して 2 回目に取れる
      (cl-letf (((symbol-function 'zellij-send--zellij-output-async)
                 (lambda (_s _args cb) (setq calls (1+ calls))
                   (funcall cb (and (> calls 1) table)))))
        (zellij-send--detect-pane-async "s00" (lambda (id cmd) (setq result (list id cmd))))
        (should (equal result '("terminal_1" "agy")))
        (should (= calls 2)))
      ;; ずっと失敗するなら上限で諦める（1 回目 + やり直し）
      (setq calls 0 result 'unset)
      (cl-letf (((symbol-function 'zellij-send--zellij-output-async)
                 (lambda (_s _args cb) (setq calls (1+ calls)) (funcall cb nil))))
        (zellij-send--detect-pane-async "s00" (lambda (id cmd) (setq result (list id cmd))))
        (should (equal result '(nil nil)))
        (should (= calls (1+ zellij-send--detect-pane-retries)))))))

(ert-deftest zellij-send-test-attach-reports-failure ()
  "ペインを特定できなかったら、黙らずに知らせる。"
  (let (shown)
    (cl-letf (((symbol-function 'zellij-send--session-cwd-async)
               (lambda (_s cb) (funcall cb nil)))
              ((symbol-function 'zellij-send--detect-pane-async)
               (lambda (_s cb &optional _tries) (funcall cb nil nil)))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
      (unwind-protect
          (progn
            (zellij-send-attach-session-async "zjs-test99")
            (should (string-match-p "zjs-test99.*特定できませんでした" shown)))
        (when (get-buffer "*ai-zjs-test99*")
          (kill-buffer "*ai-zjs-test99*"))))))

;;; スピナーの照合

(ert-deftest zellij-send-test-dashboard-spinner-case ()
  "スピナーは小文字の文言だけに一致する。質問のヒント行の Esc to cancel は拾わない。
v2.1.303 の claude は esc to interrupt を出さないので、秒数付きの形で拾う
（文言は 2026-10-19 の実機の画面から）。"
  (dolist (case `(("✳ Frobnicating… (12s · esc to interrupt)" . t)
                  ("• Working (2s • esc to interrupt)" . t)
                  ("⣾ Generating... esc to cancel" . t)
                  ("⏺ 本文\n✳ Concocting… (7s · ↓ 92 tokens)\n❯ " . t)
                  ("✽ Grooving… (4s · thinking with high effort)" . t)
                  ("· Concocting… (9s · ↓ 106 tokens)" . t)
                  ("✻ Cooked for 29s · done 19:51" . nil)
                  ("⏺ Running 1 shell command…" . nil)
                  ("  字下げした本文の… (3s のような行" . nil)
                  (,zellij-send-test--askq-single . nil)
                  (,zellij-send-test--askq-lone . nil)))
    (with-temp-buffer
      (setq-local zellij-send--last-content (car case))
      (let ((case-fold-search t))     ; 利用者の既定（t）に左右されないこと
        (should (eq (and (zellij-send--spinner-p
                          (zellij-send-session-screen (current-buffer)))
                         t)
                    (cdr case)))))))

;;; Stop フックでの取り直し

(ert-deftest zellij-send-test-on-claude-stop-narrows ()
  "Stop では、知らされたセッションの、subscribe が切れている黒板だけを取り直す。"
  (let ((a (generate-new-buffer " *zjs-stop-a*"))
        (b (generate-new-buffer " *zjs-stop-b*"))
        (live (make-process :name "zjs-live" :command '("sleep" "30") :noquery t))
        dumped)
    (unwind-protect
        (cl-letf (((symbol-function 'zellij-send--dump-screen-async)
                   (lambda (session _cb &optional _full) (push session dumped))))
          (dolist (spec `((,a "proj00") (,b "proj01")))
            (with-current-buffer (car spec)
              (setq major-mode 'zellij-send-mode)
              (setq-local zellij-send--session (cadr spec))
              (setq-local zellij-send--pane-id "terminal_1")))
          ;; セッションを知らされたら、その黒板だけ
          (zellij-send--on-claude-stop "proj01" "1")
          (should (equal dumped '("proj01")))
          ;; 古いスクリプト（引数なし）なら全部
          (setq dumped nil)
          (zellij-send--on-claude-stop)
          (should (equal (sort dumped #'string<) '("proj00" "proj01")))
          ;; subscribe が画面を受け取れている黒板は取り直さない
          (with-current-buffer b
            (setq-local zellij-send--subscribe-process live)
            (setq-local zellij-send--subscribe-pane-id "terminal_1")
            (setq-local zellij-send--last-event-time (float-time)))
          (setq dumped nil)
          (zellij-send--on-claude-stop "proj01" "1" "将来の引数")
          (should-not dumped)
          ;; 繋いだが初回イベントがまだ来ていない subscribe は、生きていないとみなす
          (with-current-buffer b
            (setq-local zellij-send--last-event-time nil))
          (zellij-send--on-claude-stop "proj01" "1")
          (should (equal dumped '("proj01"))))
      (delete-process live)
      (kill-buffer a)
      (kill-buffer b))))

;;; AskUserQuestion をフックの質問で補う

(defconst zellij-send-test--askq-hook-questions
  (json-parse-string
   "[{\"question\":\"テスト用です。好きな色はどれですか？\",\"header\":\"好きな色\",\"multiSelect\":false,
      \"options\":[{\"label\":\"青\",\"description\":\"空や海の色。落ち着いた印象。画面では折り返して見えなかった続き。\"},
                   {\"label\":\"赤\",\"description\":\"情熱的で目を引く色。\"},
                   {\"label\":\"緑\",\"description\":\"自然や植物の色。目に優しい。\"}]},
     {\"question\":\"好きな果物を選んでください\",\"header\":\"好きな果物\",\"multiSelect\":true,
      \"options\":[{\"label\":\"りんご\",\"description\":\"定番\"}]}]"
   :object-type 'alist :array-type 'list :null-object nil :false-object nil)
  "フックの tool_input.questions を模したもの（質問文の頭は画面で折り返して見えない想定）。")

(ert-deftest zellij-send-test-askq-enrich ()
  "画面と照合できたら、ラベルと説明をフックの原文で置き換える。"
  (let* ((q (zellij-send--askq-parse zellij-send-test--askq-single))
         (e (zellij-send--askq-enrich q zellij-send-test--askq-hook-questions))
         (opts (plist-get e :options)))
    (should (equal (plist-get e :question) "テスト用です。好きな色はどれですか？"))
    (should (equal (plist-get (nth 0 opts) :desc)
                   "空や海の色。落ち着いた印象。画面では折り返して見えなかった続き。"))
    ;; カーソルは画面のまま。原文に無い自由入力・Chat は画面のラベル
    (should (plist-get (nth 0 opts) :focused))
    (should (equal (mapcar (lambda (o) (plist-get o :label)) opts)
                   '("青" "赤" "緑" "Type something." "Chat about this")))
    ;; 元の q は書き換えない
    (should (equal (plist-get (nth 0 (plist-get q :options)) :desc)
                   "空や海の色。落ち着いた印象。"))))

(ert-deftest zellij-send-test-askq-enrich-mismatch ()
  "質問や選択肢が画面と合わなければ、画面から読んだものをそのまま使う。"
  (let ((q (zellij-send--askq-parse zellij-send-test--askq-single)))
    ;; 質問が合わない（別の質問が 2 つ）
    (should (eq (zellij-send--askq-enrich
                 q (list (car (last zellij-send-test--askq-hook-questions))
                         (car (last zellij-send-test--askq-hook-questions))))
                q))
    ;; 質問は 1 つだが選択肢の並びが違う
    (let ((swapped (copy-tree (car zellij-send-test--askq-hook-questions))))
      (setf (alist-get 'options swapped)
            (reverse (alist-get 'options swapped)))
      (should (eq (zellij-send--askq-enrich q (list swapped)) q)))
    ;; フックが無い・質問が無い
    (should (eq (zellij-send--askq-enrich q nil) q))
    (should-not (zellij-send--askq-enrich nil zellij-send-test--askq-hook-questions))
    ;; 確認画面は補わない
    (let ((r (zellij-send--askq-parse zellij-send-test--askq-review)))
      (should (eq (zellij-send--askq-enrich r zellij-send-test--askq-hook-questions) r)))))

(ert-deftest zellij-send-test-on-claude-hook-questions ()
  "AskUserQuestion の PreToolUse でだけ質問を受け取る。"
  (let ((b (generate-new-buffer " *zjs-hook-q*"))
        (json "[{\"question\":\"Q\",\"options\":[{\"label\":\"A\",\"description\":\"d\"}]}]"))
    (unwind-protect
        (progn
          (with-current-buffer b
            (setq major-mode 'zellij-send-mode)
            (setq-local zellij-send--session "proj00"))
          (zellij-send--on-claude-hook "proj00" "1" "PreToolUse" "Bash" "" json)
          (should-not (buffer-local-value 'zellij-send--hook-questions b))
          (zellij-send--on-claude-hook "proj00" "1" "PreToolUse" "AskUserQuestion" "" "{壊れた")
          (should-not (buffer-local-value 'zellij-send--hook-questions b))
          (zellij-send--on-claude-hook "proj00" "1" "PreToolUse" "AskUserQuestion" "" json)
          (should (equal (alist-get 'question
                                    (car (buffer-local-value 'zellij-send--hook-questions b)))
                         "Q")))
      (kill-buffer b))))

(provide 'zellij-send-test)

;;; zellij-send-test.el ends here
