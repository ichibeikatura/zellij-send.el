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

(ert-deftest zellij-send-test-transcript-claude-p ()
  "Claude Code のときだけ transcript 経路に入る。"
  (let ((zellij-send-default-command "claude")) (should (zellij-send--transcript-claude-p)))
  (let ((zellij-send-default-command "/usr/local/bin/claude --resume"))
    (should (zellij-send--transcript-claude-p)))
  (let ((zellij-send-default-command "zsh")) (should-not (zellij-send--transcript-claude-p)))
  (let ((zellij-send-default-command "")) (should-not (zellij-send--transcript-claude-p))))

(provide 'zellij-send-test)

;;; zellij-send-test.el ends here
