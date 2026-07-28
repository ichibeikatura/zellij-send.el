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

(provide 'zellij-send-test)

;;; zellij-send-test.el ends here
