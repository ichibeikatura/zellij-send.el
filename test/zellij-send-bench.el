;;; zellij-send-bench.el --- 性能のインバリアントを確かめる -*- lexical-binding: t; -*-

;;; Commentary:

;; 実行方法（リポジトリのルートから。`make bench' でも同じ）:
;;
;;   emacs -Q -batch -L . -l test/zellij-send-bench.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; 受信処理の速さはコメントだけが守っていた。どちらも、うっかり
;; `string-trim' や `[ \t]+$' に戻すと 2 乗時間になって Emacs が止まる
;; 種類の退行なので、時間で見張る。機械に依存するので `make test' には入れず、
;; 手で回す。
;;
;; 閾値（1 回 10 ms）は 2026-10-19 に Apple M1 / Emacs 32.0.50 で測って決めた:
;;
;;   画面 1 枚の整形（`zellij-send--process-dump'）     今 1.9 ms  退行 43 ms
;;   （同日、受信時の整形は `zellij-send--normalize-screen' に分けた）
;;   27 KB の行の受信（`zellij-send--subscribe-handle-line'）今 0.6 ms  退行 43 ms
;;
;; 退行の欄は、行末の空白を `[ \t]+$'（`string-trim-right' も同じ）で削った
;; 場合と、受信した行を `string-trim' に通した場合。ソースのままでも
;; バイトコンパイル済みでもほぼ同じだった。元の失敗の記録（45 ms・70 ms）は
;; `zellij-send--trim-end' と `zellij-send--subscribe-handle-line' のコメントにある。

;;; Code:

(require 'ert)
(require 'benchmark)
(require 'zellij-send)
(require 'zellij-send-dashboard)

(defconst zellij-send-bench--limit-ms 10.0
  "1 回あたりの上限（ミリ秒）。")

(defun zellij-send-bench--ms (thunk)
  "THUNK の 1 回あたりの時間（ミリ秒、GC を除く）を返す。
10 回ずつ 5 組測って一番速い組を使う（ほかの処理に割り込まれた組を捨てる）。"
  (let (best)
    (dotimes (_ 5)
      (garbage-collect)
      (let* ((r (benchmark-run 10 (funcall thunk)))
             (ms (* 1000.0 (/ (- (car r) (nth 2 r)) 10))))
        (setq best (if best (min best ms) ms))))
    best))

(ert-deftest zellij-send-bench-trim-end ()
  "列の間が大きく空いた画面の整形。`A' と `B' の間に 318 個の空白がある行を 78 行。
元の失敗は 1 回 45 ms（2026-10-02、`[ \\t]+$' で削っていた頃）。"
  (let* ((line (concat "A" (make-string 318 ?\s) "B"))
         (screen (mapconcat #'identity (make-list 78 line) "\n"))
         (ms (zellij-send-bench--ms
              (lambda () (zellij-send--normalize-screen screen)))))
    (message "normalize-screen: %.2f ms" ms)
    (should (< ms zellij-send-bench--limit-ms))))

(ert-deftest zellij-send-bench-subscribe-handle-line ()
  "ペイン幅ぶんの空白が詰まった 27 KB の行の受信。
元の失敗は 1 回 70 ms（2026-10-02、行を `string-trim' に通していた頃）。
黒板の書き換え（`zellij-send--update-buffer'）は別の話なので、下書きがある
状態にして止め、解釈と整形だけを測る。"
  (let* ((rows (mapcar (lambda (i)
                         (let ((s (format "⏺ 行 %d の本文" i)))
                           (concat s (make-string (- 320 (string-width s)) ?\s))))
                       (number-sequence 1 84)))
         (json (json-serialize
                `((event . "pane_update") (is_initial . :false)
                  (pane_id . "terminal_1") (scrollback . :null)
                  (viewport . ,(vconcat rows))))))
    (should (> (string-bytes json) 27000))
    (with-temp-buffer
      (setq-local zellij-send--session "bench00")
      (insert "下書き")
      (set-buffer-modified-p t)
      (let ((ms (zellij-send-bench--ms
                 (lambda ()
                   (setq zellij-send--last-content nil)
                   (zellij-send--subscribe-handle-line json)))))
        (message "subscribe-handle-line: %.2f ms" ms)
        (should zellij-send--last-content)
        (should (< ms zellij-send-bench--limit-ms))))))

;; 2026-10-20 に測った値（同じ機械）:
;;
;;   「状況」列（`zellij-send-dashboard--tail-line'）表 0.04 ms・罫線 1.9 ms
;;   退行（行を `string-trim' に戻した場合）        表 0.60 ms・罫線 23.7 ms

(ert-deftest zellij-send-bench-dashboard-tail-line ()
  "ダッシュボードの「状況」列。`zellij-send-bench-trim-end' と同じ画面を食わせる。
同じ画面だと最終行が意味のある行なので 1 行しか読まない。下から 40 行を
全部読ませるため、読み飛ばす行（罫線）の間を 318 個の空白で空けた画面も測る。
行を `string-trim' で削ると、1 行ごとに空白の連なりの長さの 2 乗かかる。"
  (let* ((table (concat "A" (make-string 318 ?\s) "B"))
         (border (concat "│" (make-string 318 ?\s) "│"))
         (zellij-send-dashboard-tail-width 40))
    (dolist (case `(("表" ,table "A") ("罫線" ,border "")))
      (with-temp-buffer
        (setq-local zellij-send--last-content
                    (mapconcat #'identity (make-list 78 (nth 1 case)) "\n"))
        (let* ((buf (current-buffer))
               (ms (zellij-send-bench--ms
                    (lambda () (zellij-send-dashboard--tail-line buf)))))
          (message "dashboard-tail-line (%s): %.2f ms" (nth 0 case) ms)
          (should (string-prefix-p (nth 2 case)
                                   (zellij-send-dashboard--tail-line buf)))
          (should (< ms zellij-send-bench--limit-ms)))))))

(provide 'zellij-send-bench)

;;; zellij-send-bench.el ends here
