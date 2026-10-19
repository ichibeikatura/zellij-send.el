# zellij-send の検証。`make` でバイトコンパイル・テスト・checkdoc をまとめて走らせる。
# Emacs の場所は EMACS で差し替える（例: make EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs）。

EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .
SRCS   = zellij-send-parse.el zellij-send-core.el zellij-send-claude.el \
         zellij-send-ui.el zellij-send.el zellij-send-dashboard.el
TESTS  = test/zellij-send-test.el test/zellij-send-parse-test.el

.PHONY: check test bench compile checkdoc clean

check: compile test checkdoc

# 警告もエラーにする（警告を増やさないため）。.elc は残さない
# （テストが古い .elc を読まないように）
compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRCS); \
	status=$$?; rm -f *.elc; exit $$status

test:
	$(BATCH) -l ert $(addprefix -l ,$(TESTS)) -f ert-run-tests-batch-and-exit

# 性能の見張り（1 回 10 ms を超えたら失敗）。機械に依存するので check には入れない
bench:
	$(BATCH) -l ert -l test/zellij-send-bench.el -f ert-run-tests-batch-and-exit

# 日本語の docstring に対する誤検知（句点「。」を文末と見なさない等）が多いので、
# 結果は表示するだけで失敗にはしない
checkdoc:
	@for f in $(SRCS); do \
	  $(BATCH) --eval "(progn (require 'checkdoc) (checkdoc-file \"$$f\"))" 2>&1 \
	    | grep -c ': ' | sed "s|^|checkdoc $$f: |; s|$$| 件（参考）|"; \
	done

clean:
	rm -f *.elc test/*.elc
