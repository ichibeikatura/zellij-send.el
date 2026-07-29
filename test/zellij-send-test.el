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

(provide 'zellij-send-test)

;;; zellij-send-test.el ends here
