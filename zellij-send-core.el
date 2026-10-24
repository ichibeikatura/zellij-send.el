;;; zellij-send-core.el --- Talking to zellij panes for zellij-send -*- lexical-binding: t -*-

;; Copyright (C) 2026 桂市兵衛
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: 桂市兵衛
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/ichibeikatura/zellij-send.el

;;; Commentary:

;; zellij を呼ぶ層。黒板ごとの状態（セッション・pane-id・受け取った画面）、
;; エージェントの対応表（`zellij-send-agents'）、送信・`dump-screen'・`subscribe'、
;; ペインに打ち込む非同期の操作（`zellij-send-op'）、キー透過モード、
;; 背景セッションの拡幅。黒板の描画は上の層が持つので、受信した画面は
;; `zellij-send--display-function' を通して渡す（依存は上から下の一方向）。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'zellij-send-parse)

(defcustom zellij-send-executable "zellij"
  "Path to the zellij executable."
  :type 'string
  :group 'zellij-send)

(defcustom zellij-send-default-command "claude"
  "新規セッションで起動するコマンドの既定値。
実際に何が動いているかはセッションごとに違うので、機能の分岐には
バッファローカルの `zellij-send--command' を使うこと。"
  :type 'string
  :group 'zellij-send)

;;; エージェントの対応表

;; エージェントごとの知識はここ（`zellij-send-agents'）に集める。4 体目の CLI を
;; 足すときに埋めるのはこの表の 1 行だけ。能力の名前と意味は
;; `zellij-send--capabilities'。読むだけの機能は `zellij-send--capable-p'（推測あり）、
;; ペインに打ち込む機能は `zellij-send--assert-capability'（確定が要る）で問い合わせる。
;;
;; 2026-10-19 に、次の 6 つの defcustom をこの表にまとめた（README の移行表）:
;; `zellij-send-commands' / `zellij-send-interpreters' / `zellij-send-prompt-marker-alist' /
;; `zellij-send-slash-support-alist' / `zellij-send-number-reply-commands' /
;; `zellij-send-progress-file-alist'。以下はそれぞれの docstring にあった実測と注意で、
;; 要約せずにそのまま移した。
;;
;; [zellij-send-commands]
;; `agy' は Antigravity CLI の実行ファイル名（`antigravity' ではない）。
;;
;; 送信・subscribe・キー透過モード・ダッシュボードは画面を解釈しないので
;; どのコマンドでも動く。Claude Code の画面や成果物に依存する機能
;; （transcript 表示・スラッシュコマンド・AskUserQuestion の解析）だけが
;; `zellij-send--claude-p' で分岐する。
;; （→ 今は能力の問い合わせで分岐する）
;;
;; [zellij-send-interpreters]
;; `zellij-send--command-name' は、先頭トークンがこの一覧にあるときだけ
;; 残りのトークンからエージェント名を探す。実測で codex は
;; `node /opt/homebrew/bin/codex' として COMMAND 列に出るため必要だが、
;; **無条件に全トークンを見ると `cat /tmp/claude' も claude と判定する**
;; （astra のレビューで指摘）。先読みの許可条件に使う判定なので絞っておく。
;; （→ `zellij-send--interpreters'）
;;
;; [zellij-send-prompt-marker-alist]
;; agy の許可ダイアログは ASCII の `> 1. Yes' なので `>' が要るが、
;; **これを全 CLI で有効にすると本文中の markdown 引用（`> 1. …'）を
;; 選択肢と誤検出する**。誤検出は表示だけの問題ではない——ダッシュボードの
;; 数字キー（`1' `2' `3'）は `zellij-send--detect-prompt' を許可条件に
;; しているので、誤検出した状態でユーザーが押すと、選択のつもりの数字が
;; **ただの入力**としてペインに届く（astra のレビューで指摘）。
;;
;; そのため `>' は agy のバッファでだけ有効にする。**agy 内での誤検出は
;; 残る**（agy 自身の出力に `> 1. …' があれば拾う）。
;;
;; [zellij-send-number-reply-commands]
;; 送り方は本文と同じ `paste' + CR なので、受け手が貼り付けられた数字を
;; 選択として扱うかどうかは CLI ごとに違う（2026-09-07 実測）:
;;
;;   claude  ○  選択肢は数字キーが直接効く
;;   agy     ○  許可ダイアログ `> 1. Yes' に `paste' + CR の `1' で確定した
;;   codex   ×  **数字キーを受け付けない**。信頼確認の画面に `1' を送っても
;;              何も起きず `Press enter to continue' のままで、Enter で確定した
;;
;; 一覧に無いエージェントではキー透過モード（`zellij-send-keys-mode'）の
;; ↑↓ と RET で選ぶ。あれは画面を解釈せず生のキーを送るのでどこでも効く。
;; **未確認の CLI をここに足さないこと**——選択ではない別の操作になりうる。
;;
;; [zellij-send-slash-support-alist]
;; `zellij-send-compact' / `zellij-send-cc-clear' はこの表を見て、
;; 対応が判っていないコマンドのときは送らない。「テキストを送るだけだから
;; どの CLI でも許可」は妥当ではない——受け取った側は本文として解釈し、
;; そのまま作業を始めてしまう。
;;
;; - claude / codex: `/compact' と `/clear' の両方を持つ
;;   （codex は公式ドキュメントで確認。ただし実行中は無効）
;; - agy（Antigravity CLI）: **`/compact' は無い**。2026-09-07 に
;;   ペインの補完メニューで `/comp' と打って `No matches' を確認した
;;   （本人は「ある」と答えたが実機は否定した。自己申告を信用しないこと）。
;;   `/clear'（Clear conversation and start a new one）はある。
;;   近いのは `/context'（Visualize current context usage）だが別物
;;
;; [zellij-send-progress-file-alist]
;; 一覧に無いエージェントには `zellij-send-progress-file-default' を使う。
;; CLAUDE.md を無条件に指定すると codex が読まないファイルに書かせることになる。
;;
;; agy の GEMINI.md は**実機で確認済み**（2026-09-07。合言葉を書いた
;; GEMINI.md を置いた使い捨てディレクトリで agy を起動し、その合言葉を
;; 返すことを確認した）。agy は `/compact' の有無について実機と食い違う
;; 回答をしたので、**自己申告だけで表に足さないこと**。

(defconst zellij-send--capabilities
  '((number-reply     . "選択肢に数字（本文と同じ paste + CR）で答えられる")
    (compact          . "/compact を持つ")
    (clear            . "/clear を持つ")
    (slash-completion . "補完メニューを読んでスラッシュコマンドを選べる（Claude Code の画面）")
    (askq             . "AskUserQuestion の画面を読んで答えられる（Claude Code の画面）")
    (transcript       . "会話履歴（JSONL）を読める（Claude Code の transcript）")
    (output-log       . "Stop フックが書く出力ログを読める（Claude Code の hooks）")
    (remote-control   . "起動時に --remote-control SESSION を付けられる（Claude Code）")
    (join-wrapped     . "ペイン幅で入った改行を黒板でつなぎ直せる（Claude Code の画面）")
    (strip-margin     . "画面の左 2 桁の余白を黒板で詰められる（Claude Code の画面）"))
  "`zellij-send-agents' の `:capabilities' に書ける能力と、その意味。")

(defcustom zellij-send-agents
  '(("claude" :progress-file "CLAUDE.md"
     :capabilities (number-reply compact clear slash-completion askq
                    transcript output-log remote-control join-wrapped
                    strip-margin))
    ("codex"  :progress-file "AGENTS.md"
     :capabilities (compact clear))
    ("agy"    :prompt-marker "[❯›>]" :progress-file "GEMINI.md"
     :capabilities (number-reply clear)))
  "エージェント（ペインで動かす CLI）ごとの知識の対応表。

各要素は (NAME . PLIST)。NAME は実行ファイル名で、`[New]' で選ぶ候補にも、
起動コマンドからエージェントを見分けるのにも使う。PLIST に書けるもの:

  :prompt-marker  選択肢プロンプトのカーソル記号の正規表現。
                  省けば `zellij-send-prompt-marker-regexp'
  :progress-file  `zellij-send-save-progress' が書かせるファイル。
                  省けば `zellij-send-progress-file-default'
  :capabilities   能力のシンボルのリスト（`zellij-send--capabilities'）

**実機で確かめた能力だけを書くこと。** エージェントの自己申告は信用しない
（agy は `/compact' が「ある」と答え、実機が否定した）。足し忘れた能力は
断られるだけだが、確かめずに足すと、選択のつもりの数字や `/compact' が
本文としてペインに届く。実測の記録はこの変数の定義の前のコメントにある。"
  :type '(alist :key-type (string :tag "実行ファイル名")
                :value-type (plist :tag "知識"))
  :group 'zellij-send)

(defconst zellij-send--interpreters '("node" "bun" "deno" "python" "python3"
                                      "ruby" "perl" "npx" "uv" "uvx")
  "エージェントを起動しうるインタプリタの実行ファイル名。
`zellij-send--command-name' が、先頭トークンがこれのときだけ残りのトークンから
エージェント名を探す（定義の前のコメントの [zellij-send-interpreters]）。")

(defconst zellij-send--capability-errors
  '((number-reply     . "数字での回答は %s では確認できていません。C-c C-t のキー透過モードで ↑↓ と RET を使ってください")
    (compact          . "/compact に対応しているか判らないので送りません（%s）。本文として送るなら C-c C-c を使ってください")
    (clear            . "/clear に対応しているか判らないので送りません（%s）。本文として送るなら C-c C-c を使ってください")
    (slash-completion . "スラッシュコマンドの補完は Claude Code 専用です（%s）。本文として送るか C-c C-t のキー透過モードを使ってください")
    (askq             . "AskUserQuestion の解析は Claude Code 専用です（%s）。C-c C-t のキー透過モードを使ってください"))
  "`zellij-send--assert-capability' が断るときの文面。%s はエージェント名。")

(defun zellij-send--agent-names ()
  "`zellij-send-agents' にあるエージェント名のリストを返す。"
  (mapcar #'car zellij-send-agents))

(defun zellij-send--agent-entry (name)
  "エージェント NAME の `zellij-send-agents' の要素を返す。無ければ nil。
同じ名前が無ければ、NAME がその名前で始まる要素を使う（`claude-beta' のような
派生の実行ファイル名。かつての `string-prefix-p' による判定と同じ扱い）。"
  (and name
       (or (assoc name zellij-send-agents)
           (seq-find (lambda (a) (string-prefix-p (car a) name))
                     zellij-send-agents))))

(defun zellij-send--agent-get (name prop)
  "エージェント NAME の PLIST から PROP の値を返す。"
  (plist-get (cdr (zellij-send--agent-entry name)) prop))

(defun zellij-send--agent-capable-p (name cap)
  "エージェント NAME が能力 CAP を持つと表にあれば non-nil。NAME が nil なら nil。"
  (and (memq cap (zellij-send--agent-get name :capabilities)) t))

;;; 設定と黒板ごとの状態

(defcustom zellij-send-remote-control nil
  "非 nil なら、新規に作る Claude Code のセッションを Remote Control 付きで起動する。

起動コマンドに `--remote-control SESSION' を足すので、claude.ai や
Claude モバイルアプリのセッション一覧に zellij のセッション名（`myproj00'）で
出てくる。画面を読まないので壊れにくい。起動済みのセッションを後から繋ぐには、
`/remote-control' を送ってメニューをキー透過モードで操作する。

効くのは `[New]' と `zellij-send-add-agent' で**これから作る**セッションだけ。
claude 以外のコマンドには付けない。"
  :type 'boolean
  :group 'zellij-send)

(defcustom zellij-send-prompt-marker-regexp "[❯›]"
  "選択肢プロンプトのカーソル記号にマッチする正規表現（既定値）。

3 つの CLI で**行の形は同じ**（記号 + 空白 + 数字 + ピリオド）で、
記号だけが違う（すべて実測）:

  claude  `❯ 1. りんご'
  codex   `› 1. gpt-6-astra (current)'   （Select Model / 信頼確認）
  agy     `> 1. Yes'                     （コマンド実行の許可）

記号を差し替えるだけで、プロンプト検出・ハイライト・ダッシュボードの
「選択待ち」判定・数字送信がそのまま効く。

`❯' と `›' はまず本文に現れないのでここに入れてある。**ASCII の `>' は
markdown 引用（`> 1. …'）と衝突する**ので、ここではなく
`zellij-send-agents' の `:prompt-marker' で agy のバッファに限って有効にする。
`:prompt-marker' を持たないエージェントはこの値を使う。"
  :type 'regexp
  :group 'zellij-send)

(defun zellij-send--prompt-marker ()
  "このバッファで使う選択肢プロンプトの記号正規表現を返す。
エージェントが確定していなければ（推測で代用せず）既定の記号を使う。"
  (or (zellij-send--agent-get (zellij-send--agent-name) :prompt-marker)
      zellij-send-prompt-marker-regexp))

(defcustom zellij-send-term "xterm-256color"
  "zellij をサブプロセス起動する際に設定する TERM 環境変数。
Emacs はサブプロセスに既定で TERM=dumb を渡すため、これがそのまま
zellij サーバ・ペインに継承され、ペイン内のシェルでも TERM=dumb と
なり starship 等が無効化される。サーバを起動する `attach
--create-background' とペインを生む `run' をこの値で起動して回避する。"
  :type 'string
  :group 'zellij-send)

(defcustom zellij-send-session-size '(320 . 80)
  "新規セッションを広げる大きさ (COLUMNS . LINES)。nil なら広げない。

`attach --create-background' で作った背景セッションは 50 桁 × 48 行に固定され、
**環境変数 COLUMNS / LINES では変えられない**（実測。CLAUDE.md 参照）。
唯一効くのが「この大きさの pty を持つクライアントで一瞬 attach して detach する」
方法で、`zellij-send--resize-session' がそれを行う。

Claude Code は自分でペイン幅に合わせて改行を入れて出力するので、50 桁のままだと
日本語が 24 文字程度で折り返されて読みにくい。広げておくと長い行のまま届き、
Emacs 側で好きなように折り返せる。"
  :type '(choice (const :tag "広げない" nil)
                 (cons (integer :tag "桁") (integer :tag "行")))
  :group 'zellij-send)

(defcustom zellij-send-resize-detach-delay 2.0
  "拡幅用の attach クライアントを detach するまでの待ち時間（秒）。
クライアントが繋がって pty の大きさがセッションに伝わるのを待つ。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-resize-timeout 8.0
  "拡幅用の attach クライアントを生かしておく上限（秒）。
detach が効かなくてもこの時間で必ずプロセスを殺す。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-restore-session-size t
  "non-nil なら、ターミナルが切れて縮んだままのセッションを広げ直す。
セッションの監視（`zellij-send-start-session-watch'）のたびに見て、
`zellij-send-session-size' より小さく、attach しているクライアントが
居なければ `zellij-send--resize-session' で戻す
（`zellij-send--restore-session-size'）。"
  :type 'boolean
  :group 'zellij-send)

(defcustom zellij-send-subscribe-initial-timeout 15.0
  "subscribe 接続後、最初のイベントを待つ上限（秒）。
これを過ぎても何も来なければ接続失敗とみなして再接続する。

終了コードで失敗を判定できないため必要。存在しないセッションを指定すると
`zellij subscribe' は**終了コード 0 のまま**何も流さずに終わる（実測）。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-subscribe-max-retries 5
  "subscribe の再接続を連続で何回失敗したらあきらめるか。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-subscribe-backoff-max 30.0
  "subscribe 再接続の待ち時間の上限（秒）。1, 2, 4... と倍にしていく。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-quit-timeout 10.0
  "`zellij-send-quit' が /exit の効果を待つ上限（秒）。
これを超えたら `delete-session --force' に切り替える。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-quit-poll-interval 0.5
  "`zellij-send-quit' がセッションの消滅を確認する間隔（秒）。"
  :type 'number
  :group 'zellij-send)

(defcustom zellij-send-transcript-dir "~/.claude/projects"
  "Claude Code が会話履歴（JSONL）を置くディレクトリ。"
  :type 'directory
  :group 'zellij-send)

(defcustom zellij-send-transcript-peek-bytes 131072
  "transcript の題名を探すときに読むファイル両端のバイト数。
ai-title 行は会話が進むたび追記されるので末尾側にある（実測 86 本で
末尾から最も遠いもので 47 KB）。1 本 2 MB の履歴が何十本もあるため
全文は読まず、末尾（ai-title）と先頭（最初の発言）だけを読む。"
  :type 'integer
  :group 'zellij-send)

(defcustom zellij-send-log-file ".zellij-send/claude-log.md"
  "Claude の出力ログファイルのパス（セッション作業ディレクトリからの相対）。
実際の追記は Stop フック（stop-zellij-send.sh）が行うため、
変更する場合はフックスクリプト側も合わせること。
フックはこのファイルが上限（スクリプト冒頭の `ZJS_LOG_MAX_BYTES'）を超えると
`claude-log.1.md' の形の名前へ退避して新しく始める（`zellij-send-open-log'）。"
  :type 'string
  :group 'zellij-send)

(defvar-local zellij-send--session nil
  "このバッファに対応する zellij セッション名。")

(defvar-local zellij-send--pane-id nil
  "送信先ペインの ID（例: \"terminal_2\"）。
新規作成時は `zellij run' の出力から、既存セッションへの接続時は
`list-panes --all' から取る（`zellij-send--detect-pane-async'）。
nil の場合は focused pane に送る（attach クライアントが必要）。")

(defvar-local zellij-send--command nil
  "このバッファのペインで動いているコマンド（例: \"claude\"・\"codex\"）。
新規作成時は選んだコマンド、既存セッションへの接続時は
`list-panes --all' の COMMAND 列から復元する。判らなければ nil。

エージェント 1 体 = zellij セッション 1 つなので、claude と codex を
同時に開ける。**Claude Code 専用機能の分岐にはこちらを使い、
`zellij-send-default-command' を見ないこと**（あれは新規作成時の
既定値でしかない）。")

(defvar-local zellij-send--wrap t
  "非 nil なら、この黒板は画面を映している間も折り返す。
黒板を開いたときに `zellij-send-wrap-screen' で初期化し、
`zellij-send-toggle-wrap' で切り替える。")

(defvar-local zellij-send--subscribe-process nil
  "このバッファに紐づく `zellij subscribe' の常駐プロセス。")

(defvar-local zellij-send--subscribe-timer nil
  "初回イベント待ちタイムアウト、または再接続待ちのタイマー。")

(defvar-local zellij-send--subscribe-pending ""
  "subscribe の受信途中データ。1 イベントが約 8 KB あり複数回に分かれて届くため、
改行までを溜めてから 1 行ずつ JSON として解釈する。")

(defvar-local zellij-send--subscribe-pane-id nil
  "現在の subscribe 接続が使っている pane-id。
`zellij-send--pane-id' と食い違ったら張り直す。")

(defvar-local zellij-send--subscribe-retries 0
  "subscribe の連続失敗回数。イベントを 1 つでも受け取ったら 0 に戻す。")

(defvar-local zellij-send--last-event-time nil
  "最後に subscribe イベントを受け取った時刻（`float-time'）。")

(defvar-local zellij-send--last-change-time nil
  "画面内容が最後に変化した時刻（`float-time'）。
バッファ更新を抑止している間（編集中・クリア後）も記録し続ける。
ダッシュボードの「作業中」判定はこれを見る。")

(defvar-local zellij-send--last-content nil
  "最後に受け取った画面内容。更新を抑止していても変化の検出には使う。")

(defvar-local zellij-send--user-cleared nil
  "ユーザーが意図してクリアした場合 non-nil。自動更新・Stop フックの上書きを防ぐ。")

(defvar-local zellij-send--pending-content nil
  "選択中に届き、反映を保留している画面内容（最新の 1 つだけ）。
`erase-buffer' はマークを point-min に潰すので、region が有効な間は
黒板を書き換えない。選択が解けたら `zellij-send--pending-resume' が反映する。")

(defvar-local zellij-send--reply-main-buffer nil
  "返信バッファを開いた元の zellij-send バッファ。")

(defvar-local zellij-send--reply-window-config nil
  "返信バッファを開く前のウィンドウ構成。")

(defun zellij-send--assert-session ()
  "カレントバッファが zellij-send セッションに紐付いていなければ `user-error' を投げる。
マクロにしないのは、文面を直したときに呼び出し元すべての再コンパイルが要らない
ようにするため（elpaca の古いビルドが残ると古い文面が出続ける）。"
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません")))

;;; セッションのコマンド（多 CLI 対応）

;; エージェント 1 体 = zellij セッション 1 つなので、動いているコマンドも
;; 黒板バッファごとに違う。`zellij-send-default-command' は新規作成時の
;; 既定値でしかないため、機能の分岐には必ずバッファローカルの
;; `zellij-send--command' を使う（claude と codex を同時に開けるように）。
;;
;; 画面を解釈しない機能——送信・subscribe・キー透過モード・ダッシュボード——は
;; どのコマンドでも動く。CLI ごとに違う機能は `zellij-send-agents' の能力で
;; 囲うこと（読むだけなら `zellij-send--capable-p'、打ち込むなら
;; `zellij-send--assert-capability'）。

(defun zellij-send--command-name (command)
  "COMMAND 文字列からエージェント名を返す。判らなければ nil。

基本は**先頭トークンの実行ファイル名**。ただし先頭が
`zellij-send--interpreters' のいずれかなら、残りのトークンから
`zellij-send-agents' の名前を探す（実測: codex は
`node /opt/homebrew/bin/codex' として COMMAND 列に出る）。

インタプリタに限るのは、全トークンを無条件に見ると `cat /tmp/claude' の
ような引数まで拾って claude と判定してしまうため。この判定は
打ち込む機能の許可条件（`zellij-send--assert-capability'）に使うので、
**誤って claude と読む方が危険**。"
  (let* ((names (mapcar #'file-name-nondirectory
                        (split-string (or command "") nil t)))
         (head (car names)))
    (if (member head zellij-send--interpreters)
        (or (seq-find (lambda (n) (member n (zellij-send--agent-names)))
                      (cdr names))
            head)
      head)))

(defun zellij-send--buffer-command ()
  "このバッファのペインで動いているエージェント名を返す。
`zellij-send--command' が空なら `zellij-send-default-command' で代用する
（コマンドを特定できなかった既存セッションでも従来どおり振る舞うため）。"
  (zellij-send--command-name (or zellij-send--command
                                 zellij-send-default-command)))

(defun zellij-send--capable-p (cap)
  "このバッファのエージェントが能力 CAP を持つなら non-nil（**推測あり**）。
コマンドが判らないときは `zellij-send-default-command'（普通は claude）で
代用する——読むだけの機能（transcript 表示・出力ログ）なら外しても実害が
無いため。**ペインに打ち込む機能では使わない**。そちらは
`zellij-send--assert-capability' か `zellij-send--confirmed-capable-p'。"
  (zellij-send--agent-capable-p (zellij-send--buffer-command) cap))

(defun zellij-send--launch-command (command session)
  "SESSION で実際に起動するコマンド文字列を COMMAND から作る。

Claude Code（能力 `remote-control'）で、`zellij-send-remote-control' が
非 nil か、COMMAND に `--remote-control' が既に入っているなら、末尾に
`--remote-control SESSION'
を付けて返す。既存の `--remote-control [NAME]' は外してから付け直す
——`zellij-send-add-agent' が引き継いだコマンドに前のセッション名が
残っていると、スマホ側に同じ名前が 2 つ並ぶため。
それ以外は COMMAND をそのまま返す。"
  (let* ((tokens (split-string command nil t))
         (has-flag (member "--remote-control" tokens)))
    (if (not (and (or zellij-send-remote-control has-flag)
                  (zellij-send--agent-capable-p
                   (zellij-send--command-name command) 'remote-control)))
        command
      (let (kept)
        (while tokens
          (if (equal (car tokens) "--remote-control")
              ;; 名前は省略できるので、次がオプションでなければ名前として捨てる
              (setq tokens (if (and (cdr tokens)
                                    (not (string-prefix-p "-" (cadr tokens))))
                               (cddr tokens)
                             (cdr tokens)))
            (push (car tokens) kept)
            (setq tokens (cdr tokens))))
        (string-join (append (nreverse kept) (list "--remote-control" session))
                     " ")))))

(defun zellij-send--agent-name ()
  "**確定している**エージェント名を返す。判っていなければ nil。
`zellij-send--buffer-command' と違い `zellij-send-default-command' で
代用しない。"
  (and zellij-send--command (zellij-send--command-name zellij-send--command)))

(defun zellij-send--confirmed-capable-p (cap)
  "このバッファのエージェントが能力 CAP を持つと**確定している**なら non-nil。
コマンドを特定できなかったセッションでは nil（既定値で代用しない）。
推測で代用すると、別の CLI の入力欄に打ち込んでしまう（astra のレビューで指摘）。
断るときの文面が要るなら `zellij-send--assert-capability' を使う。"
  (zellij-send--agent-capable-p (zellij-send--agent-name) cap))

(defun zellij-send--assert-capability (cap)
  "このバッファのエージェントが能力 CAP を持つと確定していなければ `user-error'。
**ペインに打ち込む機能はこれで守る**——数字での回答・`/compact' `/clear'・
スラッシュコマンドの補完・AskUserQuestion の操作。文面は
`zellij-send--capability-errors'。"
  (unless (zellij-send--confirmed-capable-p cap)
    (user-error (alist-get cap zellij-send--capability-errors)
                (or (zellij-send--agent-name) "コマンド不明"))))

;;; セッション一覧の取得

(defun zellij-send-list-sessions (callback)
  "list-sessions を非同期で実行し、結果を CALLBACK に渡す。結果は次のどちらか:

  (:ok SESSIONS)    SESSIONS はセッション名のリスト（0 件なら nil）
  (:failed REASON)  タイムアウト（5 秒）か異常終了。REASON はユーザーに見せる文

セッションが 0 件のときも zellij は exit 1 を返す（stderr に
\"No active zellij sessions found.\"）。これだけは 0 件として扱い、
それ以外の異常終了は 0 件と区別する。呼び出し側はセッションの無い
バッファを kill するので、失敗を 0 件と読むと生きている黒板が消える。
成否は結果の先頭（`:ok' か `:failed'）で見ること。2026-10-19 までは
成功をリスト、失敗を `:timeout' / `:error' で返していて、呼び出し側が
`listp' で見分けていた（nil も `listp' を満たすので取り違えやすかった）。

stderr は別バッファに分けず stdout と同じバッファで受ける。分けると
stderr 側のパイプが読み終わる前に sentinel が走ることがあり、
0 件の案内文を見落として失敗と読む。案内文の行は
`zellij-send--parse-sessions' が捨てる。

公開 API（ダッシュボードも使う）。2026-10-20 までは内部名
`zellij-send--list-sessions-async' の別名だったので、取得の経路が 2 つに
見えていた。"
  (let* ((out-buf (generate-new-buffer " *zellij-list-sessions*"))
         (default-directory (zellij-send--process-directory))
         (done nil)
         timer proc)
    (setq proc
          (make-process
           :name "zellij-list-sessions"
           :buffer out-buf
           :noquery t
           :connection-type 'pipe
           :command (list zellij-send-executable "list-sessions")
           :sentinel
           (lambda (p _)
             (when (and (not done)
                        (memq (process-status p) '(exit signal)))
               (setq done t)
               (when timer (cancel-timer timer))
               (let* ((raw (with-current-buffer out-buf (buffer-string)))
                      (result
                       (if (or (zerop (process-exit-status p))
                               (string-match-p "No active zellij sessions" raw))
                           (list :ok (zellij-send--parse-sessions raw))
                         (list :failed "zellij のセッション一覧を取得できませんでした。zellij が正常に動作しているか確認してください。"))))
                 (ignore-errors (kill-buffer out-buf))
                 (funcall callback result))))))
    (setq timer
          (run-with-timer 5.0 nil
                          (lambda ()
                            (unless done
                              (setq done t)
                              (ignore-errors (delete-process proc))
                              (ignore-errors (kill-buffer out-buf))
                              (funcall callback
                                       (list :failed "zellij の応答がタイムアウトしました（5秒）。zellij が正常に動作しているか確認してください。"))))))))

;;; 送信

(defun zellij-send--process-environment ()
  "zellij を起動するための `process-environment' を返す。
TERM を `zellij-send-term' に差し替える（Emacs 既定の TERM=dumb が
zellij サーバ・ペインに継承されるのを防ぐ）。

かつてここで COLUMNS / LINES も渡していた（`zellij-send-session-size'）が、
**zellij 0.44.3 では効果が無いと実測で確認したので削除した**。
背景セッションは 50 桁 × 48 行で固定される。詳細は CLAUDE.md
「背景セッションの大きさ」を参照。"
  (cons (concat "TERM=" zellij-send-term) process-environment))

(defun zellij-send--process-directory ()
  "zellij を起動するときの `default-directory' を返す。
カレントバッファのディレクトリが無ければホームにする。`make-process' は
`default-directory' に移れないと起動の前に失敗する（file-missing）。
zellij の呼び出しは作業ディレクトリに依らない（ペインの cwd は `run --cwd'
で渡す）が、タイマーや sentinel はたまたまカレントだったバッファで動くので、
ディレクトリの消えた黒板が 1 つあるだけで監視も送信も失敗した
（2026-10-20 手元確認）。リモートのディレクトリはそのまま返す（調べると
接続が走る）。"
  (if (or (file-remote-p default-directory)
          (file-accessible-directory-p default-directory))
      default-directory
    (expand-file-name "~/")))

(defun zellij-send--zellij-async (args &optional callback)
  "zellij を ARGS で非同期実行する。
終了したら CALLBACK に exit code を渡して呼ぶ（CALLBACK は省略可）。
同期 `call-process' は使わない: Emacs の UI をブロックし、
zellij サーバ側の都合で応答が遅れた場合にフリーズするため。
TERM を上書きして起動する（サーバを起動する `attach
--create-background' が TERM=dumb をペインに伝播させないため）。"
  (let ((process-environment (zellij-send--process-environment))
        (default-directory (zellij-send--process-directory)))
    (make-process
     :name "zellij-async"
     :buffer nil
     :noquery t
     :command (cons zellij-send-executable args)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (when callback
           (funcall callback (process-exit-status proc))))))))

(defun zellij-send--pane-args ()
  "カレントバッファの `zellij-send--pane-id' から --pane-id 引数リストを返す。
pane-id 不明なら nil（focused pane への送信になる）。"
  (when zellij-send--pane-id
    (list "--pane-id" zellij-send--pane-id)))

(defun zellij-send--send (session text &optional callback)
  "SESSION に TEXT を送り、続けて Enter キー（0x0D）を非同期送信する。
カレントバッファに `zellij-send--pane-id' があればそのペインへ、
なければ focused pane へ送る（後者は attach クライアントが必要）。
完了したら CALLBACK に成功なら t、失敗なら nil を渡して呼ぶ（省略可）。
失敗時はメッセージも表示する。

本文は `write-chars' ではなく `paste'（bracketed paste）で送る。
`write-chars' は改行を LF のまま渡すため、LF で入力を確定する受け手
（シェルなど）だと複数行テキストが行ごとに実行されてしまう。
`paste' は受け手が bracketed paste を有効にしている時だけマーカーで
包むので、対応していないペインへ送っても余計な文字は現れない。"
  (let ((pane-args (zellij-send--pane-args)))
    (zellij-send--zellij-async
     (append (list "--session" session "action" "paste")
             pane-args (list "--" text))
     (lambda (exit1)
       (if (not (zerop exit1))
           (progn
             (message "zellij テキスト送信失敗 (exit: %d)" exit1)
             (when callback (funcall callback nil)))
         (zellij-send--zellij-async
          (append (list "--session" session "action" "write")
                  pane-args (list "--" "13"))
          (lambda (exit2)
            (if (not (zerop exit2))
                (progn
                  (message "zellij Enter 送信失敗 (exit: %d)" exit2)
                  (when callback (funcall callback nil)))
              (when callback (funcall callback t))))))))))

(defun zellij-send--send-keys (session bytes &optional callback)
  "SESSION の対象ペインに BYTES（数値のリスト）をキー入力として送る。
カレントバッファの `zellij-send--pane-id' を使うので、必ず対象バッファを
カレントにして呼ぶこと。テキストではなく制御文字を送るための入口
（例: Esc = 27）。"
  (zellij-send--zellij-async
   (append (list "--session" session "action" "write")
           (zellij-send--pane-args)
           (list "--")
           (mapcar #'number-to-string bytes))
   callback))

;;; スクリーンダンプ

(defun zellij-send--dump-screen-async (session callback &optional full drop-faint)
  "SESSION のスクリーン内容を非同期で取得する（STDOUT 直読み・zellij 0.44+）。
カレントバッファに `zellij-send--pane-id' があればそのペインをダンプする。
取得できたら画面の正規形（`zellij-send--normalize-screen'）を、失敗時は nil を
引数にして CALLBACK を呼ぶ。
CALLBACK は要求元バッファをカレントにした状態で呼ばれる。

FULL が非 nil なら `--full' を付けてスクロールバックまで取る。
**Claude Code には効かない**。alt-screen の TUI には仕様上スクロールバックが
無いため、`--full' でも viewport と同じ内容しか返らない（2026-07-28 実測）。
alt-screen でないコマンド（`zellij-send--command' 参照）を動かしている
セッションのためだけに付けている。流れて消えた Claude の出力は
`zellij-send-log-file'（Stop フックが追記）で読む。

DROP-FAINT が非 nil なら `--ansi' で取り、入力欄の薄い字（ターン後の提案文）
を消した画面を渡す（`zellij-send--blank-faint-input'）。入力欄が空かを
確かめるときだけ使う。"
  (let ((req-buffer (current-buffer))
        (out-buf (generate-new-buffer " *zellij-dump*"))
        (err-buf (generate-new-buffer " *zellij-dump-err*"))
        (default-directory (zellij-send--process-directory)))
    (make-process
     :name "zellij-dump"
     :buffer out-buf
     :stderr err-buf
     :noquery t
     :command (append (list zellij-send-executable
                            "--session" session
                            "action" "dump-screen")
                      (when full (list "--full"))
                      (when drop-faint (list "--ansi"))
                      (when zellij-send--pane-id
                        (list "--pane-id" zellij-send--pane-id)))
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((content
                (when (zerop (process-exit-status proc))
                  (let ((raw (with-current-buffer out-buf (buffer-string))))
                    (zellij-send--normalize-screen
                     (if drop-faint (zellij-send--blank-faint-input raw) raw))))))
           (ignore-errors (kill-buffer out-buf))
           (ignore-errors (kill-buffer err-buf))
           (when (buffer-live-p req-buffer)
             (with-current-buffer req-buffer
               (funcall callback content)))))))))

;;; セッション情報の取得（cwd・pane-id）

(defun zellij-send--zellij-output-async (session args callback)
  "SESSION に対して zellij を ARGS で実行し、STDOUT を CALLBACK に渡す。
失敗時は nil を渡す。"
  (let ((out-buf (generate-new-buffer " *zellij-out*"))
        (err-buf (generate-new-buffer " *zellij-out-err*"))
        (default-directory (zellij-send--process-directory)))
    (make-process
     :name "zellij-output"
     :buffer out-buf
     :stderr err-buf
     :noquery t
     :command (append (list zellij-send-executable "--session" session) args)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((out (and (zerop (process-exit-status proc))
                         (with-current-buffer out-buf (buffer-string)))))
           (ignore-errors (kill-buffer out-buf))
           (ignore-errors (kill-buffer err-buf))
           (funcall callback out)))))))

(defun zellij-send--pick-pane (panes)
  "PANES（(ID COMMAND EXITED-P) のリスト）から送信先として最も妥当なものを選ぶ。

**生きているペインを優先**し、その中では `zellij-send-default-command' と
同じエージェント → `zellij-send-agents' のいずれか → 先頭、の順で選ぶ。
これで、デフォルト shell ペインが残っているセッションでもエージェントの
ペインに繋がる。

生きているペインが 1 つも無ければ同じ順で終了済みのペインから選ぶ。
エージェントが `/exit' で落ちてもペインは EXITED=true で残るので
（CLAUDE.md「セッションの終了」参照）、最後の画面を読めるようにするため。"
  (let* ((default (zellij-send--command-name zellij-send-default-command))
         (rank (lambda (list)
                 (or (car (seq-find
                           (lambda (p)
                             (equal (zellij-send--command-name (nth 1 p)) default))
                           list))
                     (car (seq-find
                           (lambda (p)
                             (member (zellij-send--command-name (nth 1 p))
                                     (zellij-send--agent-names)))
                           list))
                     (car (car list))))))
    (or (funcall rank (seq-remove (lambda (p) (nth 2 p)) panes))
        (funcall rank panes))))

(defconst zellij-send--detect-pane-retries 3
  "pane-id を特定できなかったときにやり直す回数（1 秒おき）。
2026-10-19、Emacs の起動時にダッシュボードが 3 つのセッションへまとめて
自動接続したとき、1 つだけ特定に失敗して黒板が空のまま残った（直後に
同じ処理をやり直すと取れた）。一度きりの失敗で黒板を死なせないため。")

(defun zellij-send--detect-pane-async (session callback &optional tries)
  "SESSION の送信先 pane-id と、そこで動いているコマンドを CALLBACK に渡す。
CALLBACK は 2 引数 (PANE-ID COMMAND) で呼ばれる。不明なものは nil。
取れなければ `zellij-send--detect-pane-retries' 回まで 1 秒おきにやり直す
（TRIES は何回目か）。読むだけでペインには打たないので、op の外で待つ。

`list-panes --all' を **1 回だけ**叩いて両方を得る。pane-id と
コマンドを別々に取りに行くと、その間にペインが入れ替わったときに
食い違う。"
  (let ((tries (or tries 0)))
    (zellij-send--zellij-output-async
     session '("action" "list-panes" "--all")
     (lambda (out)
       (let* ((panes (and out (zellij-send--parse-terminal-panes out)))
              (id (and panes (zellij-send--pick-pane panes)))
              (cmd (and id (nth 1 (assoc id panes)))))
         (if (and (null id) (< tries zellij-send--detect-pane-retries))
             (run-at-time 1.0 nil #'zellij-send--detect-pane-async
                          session callback (1+ tries))
           (funcall callback id cmd)))))))

(defun zellij-send--session-cwd-async (session callback)
  "SESSION の作業ディレクトリを CALLBACK に渡す（不明なら nil）。"
  (zellij-send--zellij-output-async
   session '("action" "dump-layout")
   (lambda (out)
     (funcall callback (and out (zellij-send--parse-layout-cwd out))))))

;;; プロンプト検出・ハイライト

(defun zellij-send--prompt-regexp (&optional whole-line)
  "選択肢プロンプト行にマッチする正規表現を返す。
WHOLE-LINE が非 nil なら行末までマッチする形にする（ハイライト用）。
記号は `zellij-send--prompt-marker'（エージェントごと。agy だけ ASCII の
`>' も含む）。

**行頭に限定**する（本文中に引用された選択肢を拾わないため）。番号は
2 桁以上も許す（選択肢が 10 個を超える画面がある）。それでも画面解析なので、
引用文の誤認を完全には防げない（astra のレビューで指摘）。"
  ;; 行頭の字下げと記号の後は **[ \t] に限る**。`[[:space:]]' は改行も
  ;; 含むので、`^[[:space:]]*' が直前の行末の改行から一致し、
  ;; ハイライトの overlay が 1 行上から始まってしまう（実測で確認）
  (let ((core (concat "^[ \t]*" (zellij-send--prompt-marker)
                      "[ \t]+[1-9][0-9]*\\.")))
    (if whole-line (concat core ".*$") core)))

(defun zellij-send--detect-prompt (&optional screen)
  "バッファ（SCREEN を渡せばその文字列）に選択肢プロンプトがあれば non-nil。
claude の `❯ 1. …' と codex の `› 1. …' の両方を拾う
\(`zellij-send-prompt-marker-regexp')。記号はカレントバッファの
エージェントで決まるので、SCREEN を渡すときも黒板をカレントにして呼ぶ。"
  (if screen
      (string-match-p (zellij-send--prompt-regexp) screen)
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (zellij-send--prompt-regexp) nil t))))

(defun zellij-send--last-screen ()
  "カレントの黒板が最後に受け取ったペインの画面を返す。分からなければ nil。

黒板の中身（`buffer-string'）は画面とは限らない。下書きを書いている間・
クリアした後・transcript を表示している間は、画面ではない文章が入っている。
画面を解析する処理はバッファではなくこれを読む。

subscribe が記録した `zellij-send--last-content' を優先する（更新を
抑止している間も記録され続ける）。まだ 1 件も受けていなければ、黒板が
画面を映しているとき（未編集・未クリア）だけバッファの中身で代用する。"
  (or zellij-send--last-content
      (and (not (buffer-modified-p))
           (not zellij-send--user-cleared)
           (buffer-string))))

(defun zellij-send--clear-prompt-highlight ()
  "選択肢行のハイライトを消す。"
  (remove-overlays (point-min) (point-max) 'zellij-send-prompt t))

(defun zellij-send--highlight-prompt ()
  "選択肢行をハイライトする。"
  (zellij-send--clear-prompt-highlight)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward (zellij-send--prompt-regexp t) nil t)
      (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
        (overlay-put ov 'zellij-send-prompt t)
        (overlay-put ov 'face 'highlight)))))

;;; 自動受信（zellij subscribe）

;; セッションごとに `zellij subscribe' の常駐プロセスを 1 本持ち、ペインの
;; 変化をイベントで受け取る。2 秒ごとに dump-screen のプロセスを起こす
;; ポーリングは廃止した（アイドル 20 秒でイベント 1 件に対し、ポーリングは
;; プロセス 10 個。実測）。
;;
;; 実測（zellij 0.44.3）で分かった注意点:
;; - `subscribe' は `--pane-id' が必須。pane-id 不明なら先に特定する
;; - イベントは NDJSON。viewport は差分ではなく毎回フルの行配列
;; - 1 イベント約 8 KB で複数回に分かれて届くので行単位のバッファリングが要る
;; - **セッションが消えても subscribe は終了しない**（force delete 後も
;;   17 秒以上生き続けた）。プロセスの死を検知手段にできない。バッファが
;;   kill されたときに `kill-buffer-hook' で確実に殺す
;; - 存在しないセッションを指定すると**終了コード 0 のまま**何も流れない。
;;   よって「初回イベントが来たか」で成否を判定する

(defvar zellij-send--display-function #'ignore
  "受け取った画面を黒板に映す関数。(CONTENT &optional IF-CHANGED) を受ける。
黒板の描画（`zellij-send--update-buffer'）は上の層の zellij-send-ui.el が持つ。
受信（subscribe）と Stop フックは下の層にあるので、名前で呼ばずにここを通す
（依存を上から下の一方向に保つため。zellij-send-ui.el が読み込み時に入れる）。")

(defvar zellij-send--pane-connected-hook nil
  "黒板がペインに繋がった（subscribe を張った）ときに、黒板をカレントにして走るフック。
スラッシュコマンド一覧の先読みは上の層（zellij-send-claude.el）がここに足す。")

(defun zellij-send--subscribe-stop ()
  "このバッファの subscribe プロセスとタイマーを止める。
意図的な停止なので sentinel を無効化してから殺す（再接続させないため）。"
  (when zellij-send--subscribe-timer
    (cancel-timer zellij-send--subscribe-timer)
    (setq zellij-send--subscribe-timer nil))
  (when zellij-send--subscribe-process
    (let ((proc zellij-send--subscribe-process))
      (setq zellij-send--subscribe-process nil)
      (set-process-sentinel proc #'ignore)
      (when (process-live-p proc)
        (delete-process proc))))
  (setq zellij-send--subscribe-pending ""))

(defun zellij-send--subscribe-handle-line (line)
  "subscribe から届いた 1 行 LINE を解釈してバッファに反映する。"
  ;; **`string-trim' を通してはいけない**。文字列末尾に錨を置く正規表現は
  ;; 空白の連なりごとに後戻りするので、ペイン幅ぶんの空白が詰まった
  ;; 27 KB の行では 1 回 70 ms かかった（2026-10-02 実測。作業中は毎秒
  ;; 8 回届くので Emacs が半分以上止まる）。前後の空白は `json-parse-string'
  ;; が読み飛ばすので、空行かどうかだけ先頭から見る
  (when (string-match-p "[^ \t\r]" line)
    (let* ((obj (ignore-errors
                  (json-parse-string line :object-type 'alist
                                     :array-type 'list :null-object nil)))
           (viewport (alist-get 'viewport obj)))
      ;; 読めない行や `viewport' の無いイベントを空の画面として扱わない
      ;; （`alist-get' はどちらでも nil を返し、nil は `listp' を満たす）
      (when (and (assq 'viewport obj) (listp viewport))
        (setq zellij-send--subscribe-retries 0
              zellij-send--last-event-time (float-time))
        ;; 結合する前に行ごとの右詰めの空白を落とす。`--process-dump' は
        ;; 文字列を何度も作り直すので、27 KB のまま渡すと 1 イベントで
        ;; 約 8 倍のごみが出て、GC（1 回 10 ms）が 1.5 イベントに 1 回
        ;; 走っていた（2026-10-02 実測）。正式な行末処理は ANSI 除去の後に
        ;; `--process-dump' がやるので、ここは量を減らすだけ
        ;; （2026-10-19 に `--process-dump' を `--normalize-screen' と
        ;; `--screen-for-display' に分けた。ここで通すのは前者）
        (let ((content (zellij-send--normalize-screen
                        (mapconcat (lambda (line)
                                     (zellij-send--trim-end line '(?\s ?\t)))
                                   viewport "\n"))))
          ;; 変化の記録は更新抑止中も続ける（ダッシュボードが見るため）
          (unless (equal content zellij-send--last-content)
            (setq zellij-send--last-content content
                  zellij-send--last-change-time (float-time)))
          ;; 書き換えは、ユーザーが編集中でもクリア直後でもないときだけ。
          ;; 黒板に同じものが映っていれば書き換えない（`--update-buffer' の
          ;; IF-CHANGED）。比べるのは表示形どうし
          (when (and (not (buffer-modified-p))
                     (not zellij-send--user-cleared))
            (funcall zellij-send--display-function content t)))))))

(defun zellij-send--subscribe-filter (buf out)
  "subscribe プロセスの出力 OUT を BUF で行単位に解釈する。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq zellij-send--subscribe-pending
            (concat zellij-send--subscribe-pending out))
      (let ((lines (split-string zellij-send--subscribe-pending "\n")))
        ;; 末尾は未完の行（改行で終わっていれば空文字）。次の出力に持ち越す
        (setq zellij-send--subscribe-pending (car (last lines)))
        (dolist (line (butlast lines))
          (zellij-send--subscribe-handle-line line))))))

(defun zellij-send--subscribe-schedule-retry ()
  "subscribe を指数バックオフで張り直す。上限を超えたらあきらめる。"
  (setq zellij-send--subscribe-retries (1+ zellij-send--subscribe-retries))
  (if (> zellij-send--subscribe-retries zellij-send-subscribe-max-retries)
      (message "セッション [%s] の自動更新に %d 回失敗しました（C-c C-a → a で手動取得）"
               zellij-send--session zellij-send-subscribe-max-retries)
    (let ((delay (min zellij-send-subscribe-backoff-max
                      (expt 2.0 (1- zellij-send--subscribe-retries))))
          (buf (current-buffer)))
      ;; 初回イベント待ちのタイマーが残っていれば止める。参照を上書きすると
      ;; `--subscribe-stop' で止められなくなり、後から再接続をもう 1 本起こす
      (when zellij-send--subscribe-timer
        (cancel-timer zellij-send--subscribe-timer))
      (setq zellij-send--subscribe-timer
            (run-at-time delay nil
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (setq zellij-send--subscribe-timer nil)
                               (zellij-send--subscribe-ensure)))))))))

(defun zellij-send--subscribe-check-initial (buf)
  "BUF の subscribe が初回イベントを受け取れたか確認し、駄目なら張り直す。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq zellij-send--subscribe-timer nil)
      (unless zellij-send--last-event-time
        (zellij-send--subscribe-stop)
        (zellij-send--subscribe-schedule-retry)))))

(defun zellij-send--subscribe-start ()
  "このバッファの subscribe を開始する。pane-id が分かっていることが前提。"
  (zellij-send--subscribe-stop)
  (when (and zellij-send--session zellij-send--pane-id)
    (let* ((buf (current-buffer))
           (session zellij-send--session)
           (process-environment (zellij-send--process-environment))
           (default-directory (zellij-send--process-directory)))
      (setq zellij-send--subscribe-pane-id zellij-send--pane-id
            zellij-send--last-event-time nil)
      (setq zellij-send--subscribe-process
            (make-process
             :name (format "zellij-subscribe-%s" session)
             :buffer nil
             :noquery t
             :connection-type 'pipe
             :command (list zellij-send-executable
                            "--session" session
                            "subscribe"
                            "--pane-id" zellij-send--pane-id
                            "--format" "json")
             :filter (lambda (_proc out)
                       (zellij-send--subscribe-filter buf out))
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (when (eq zellij-send--subscribe-process proc)
                       (setq zellij-send--subscribe-process nil)
                       (zellij-send--subscribe-schedule-retry))))))))
      ;; 終了コードが当てにならないので、初回イベントの有無で成否を見る
      (setq zellij-send--subscribe-timer
            (run-at-time zellij-send-subscribe-initial-timeout nil
                         #'zellij-send--subscribe-check-initial buf))
      ;; ペインに繋がった（スラッシュコマンド一覧の先読みなどがここに付く）
      (run-hooks 'zellij-send--pane-connected-hook))))

(defun zellij-send--subscribe-ensure ()
  "必要なら subscribe を（再）開始する。
既に生きていて pane-id も一致していれば何もしない。
`subscribe' は `--pane-id' 必須なので、不明なら先に特定してから張る。"
  (when (and zellij-send--session
             (not (and zellij-send--subscribe-process
                       (process-live-p zellij-send--subscribe-process)
                       (equal zellij-send--subscribe-pane-id
                              zellij-send--pane-id))))
    (if zellij-send--pane-id
        (zellij-send--subscribe-start)
      (let ((buf (current-buffer))
            (session zellij-send--session))
        (zellij-send--detect-pane-async
         session
         (lambda (pane-id command)
           (when (and pane-id (buffer-live-p buf))
             (with-current-buffer buf
               (setq-local zellij-send--pane-id pane-id)
               ;; `--subscribe-start' が先読みを呼ぶので、ここでも
               ;; コマンドを先に入れる。入れ忘れると codex のペインに
               ;; `/' を打ち込む（`zellij-send--confirmed-capable-p' 参照）。
               ;; pane-id を替えるときは **nil でも代入する**
               (setq-local zellij-send--command command)
               (zellij-send--subscribe-start)))))))))

;;; ペインへの操作（排他・中止）

;; スラッシュコマンド一覧の取得・引数の確認・AskUserQuestion への回答は、
;; どれもペインの入力欄にキーを打ちながら画面を読み、タイマーで次の段へ進む。
;; その 1 回分を `zellij-send-op' にまとめ、黒板ごとに 1 つだけ持つ（`zellij-send--op'）。
;;
;; - 排他: 別の操作が走っている間は始めない。同じ入力欄を取り合うため
;; - 中止: タイマーは必ず op に記録する（`zellij-send--op-later'）。
;;   `zellij-send--op-abort' がそれを止め、打ちかけた入力欄を片付ける
;; - 遅れて返る処理: ペインへの入出力は op が生きているときだけ行い、返って
;;   きた時点でも生きているときだけ続きを呼ぶ（`zellij-send--op-dump' など）。
;;   止めた後に、走っていた `dump-screen' のコールバックがキーを送らないため
;;
;; 2026-10-19 までは操作ごとの変数 6 つ（`--slash-collecting' `--slash-prefetching'
;; `--askq-answering' `--askq-signature' `--askq-repeat' `--askq-rounds'）に
;; 分かれていて互いを見ず、`run-at-time' の鎖も追えなかったので、C-g で
;; 止まるのは入口のミニバッファだけだった。

(cl-defstruct (zellij-send-op (:constructor zellij-send--op-make)
                              (:copier nil))
  "黒板のペインに対して非同期に進む 1 つの操作。"
  kind          ; `slash-collect' / `slash-arg' / `askq'
  buffer        ; 黒板バッファ
  started-at    ; 始めた時刻
  deadline      ; これを過ぎたら無効とみなす
  timer         ; いま待っている `run-at-time' のタイマー
  silent        ; 進捗を知らせない（先読み）
  state)        ; 操作ごとの plist

(defvar-local zellij-send--op nil
  "この黒板のペインで走っている操作（`zellij-send-op'）。無ければ nil。")

(defconst zellij-send--op-lifetimes
  '((slash-collect . 120) (slash-arg . 120) (askq . 3600))
  "操作の種類 → 始めてから無効とみなすまでの秒数。
コールバックが返らないまま残っても、永久に塞がないための歯止め。
一覧の取得は普通 8 秒前後、`zellij-send-slash-max-rounds' を使い切っても
1 分程度。回答はミニバッファで考える時間を含むので長く取る。")

(defconst zellij-send--op-busy-messages
  '((slash-collect . "スラッシュコマンド一覧を取得中です。数秒後にもう一度どうぞ")
    (slash-arg     . "スラッシュコマンドの引数を確認中です。数秒後にもう一度どうぞ")
    (askq          . "回答の途中です"))
  "別の操作が走っているときに断る文面。走っている方の種類で選ぶ。")

(defun zellij-send--op-current (&optional buf)
  "BUF（既定はカレント）で走っている操作を返す。無いか期限切れなら nil。"
  (let ((op (buffer-local-value 'zellij-send--op (or buf (current-buffer)))))
    (and op (< (float-time) (zellij-send-op-deadline op)) op)))

(defun zellij-send--op-live-p (op)
  "OP がまだ自分の黒板の操作として生きていれば non-nil。"
  (let ((buf (and op (zellij-send-op-buffer op))))
    (and buf (buffer-live-p buf) (eq (zellij-send--op-current buf) op))))

(defun zellij-send--op-begin (buf kind &rest props)
  "BUF で KIND の操作を始めて返す。別の操作が走っていれば nil。
PROPS には `:silent'（進捗を知らせない）と `:state'（操作ごとの plist）を書ける。"
  (unless (zellij-send--op-current buf)
    (with-current-buffer buf
      (let ((now (float-time)))
        (setq zellij-send--op
              (zellij-send--op-make
               :kind kind :buffer buf :started-at now
               :deadline (+ now (alist-get kind zellij-send--op-lifetimes 120))
               :silent (plist-get props :silent)
               :state (plist-get props :state)))))))

(defun zellij-send--op-busy-message (&optional buf)
  "BUF で走っている操作があれば、それを理由に断る文面を返す。無ければ nil。"
  (let ((op (zellij-send--op-current buf)))
    (and op (alist-get (zellij-send-op-kind op) zellij-send--op-busy-messages))))

(defun zellij-send--op-assert-free ()
  "カレントの黒板で別の操作が走っていれば `user-error'。"
  (let ((msg (zellij-send--op-busy-message)))
    (when msg (user-error "%s" msg))))

(defun zellij-send--op-get (op key)
  "OP の状態 plist から KEY の値を返す。"
  (plist-get (zellij-send-op-state op) key))

(defun zellij-send--op-put (op key value)
  "OP の状態 plist の KEY を VALUE にする。"
  (setf (zellij-send-op-state op) (plist-put (zellij-send-op-state op) key value)))

(defun zellij-send--op-end (op)
  "OP を終える。OP がもう黒板の操作でなければ、黒板の側には触らない。
（期限切れの後に別の操作が始まっていたら、その印を消さない。）"
  (when op
    (let ((timer (zellij-send-op-timer op))
          (buf (zellij-send-op-buffer op)))
      (when (timerp timer) (cancel-timer timer))
      (setf (zellij-send-op-timer op) nil)
      (when (and (buffer-live-p buf)
                 (eq (buffer-local-value 'zellij-send--op buf) op))
        (with-current-buffer buf
          (setq zellij-send--op nil))))))

(defun zellij-send--op-abort (buf &optional reason)
  "BUF で走っている操作を止める。止めたものがあれば non-nil。
待っているタイマーを止め、入力欄に打ちかけていれば Ctrl+U で片付ける。
走っている `dump-screen' などのコールバックは、返ってきても続きを呼ばない
（`zellij-send--op-live-p'）。REASON があれば知らせる。"
  (let ((op (and (buffer-live-p buf) (buffer-local-value 'zellij-send--op buf))))
    (when op
      (zellij-send--op-end op)
      ;; 打っていないのに Ctrl+U を送ると、ターミナル側の書きかけを消す
      (when (zellij-send--op-get op :typed)
        (with-current-buffer buf
          (zellij-send--send-keys zellij-send--session '(21) #'ignore)))
      (when reason (message "%s" reason))
      t)))

(defun zellij-send--op-later (op delay fn &rest args)
  "DELAY 秒後に FN を ARGS で呼ぶ。そのとき OP が生きていなければ呼ばない。
**ペインに打ち込む操作の `run-at-time' はすべてここを通す**——タイマーが
OP に記録されていなければ `zellij-send--op-abort' で止められない。
FN は OP の黒板をカレントにして呼ぶ。"
  (when (zellij-send--op-live-p op)
    (setf (zellij-send-op-timer op)
          (run-at-time delay nil
                       (lambda ()
                         (setf (zellij-send-op-timer op) nil)
                         (when (zellij-send--op-live-p op)
                           (with-current-buffer (zellij-send-op-buffer op)
                             (apply fn args))))))))

(defun zellij-send--op-callback (op fn)
  "FN を包んで返す。呼ばれた時点で OP が生きていなければ何もしない。
FN は OP の黒板をカレントにして呼ぶ。"
  (lambda (&rest args)
    (when (zellij-send--op-live-p op)
      (with-current-buffer (zellij-send-op-buffer op)
        (apply fn args)))))

(defun zellij-send--op-dump (op callback &optional drop-faint)
  "OP の黒板のペインの画面を取り、CALLBACK に渡す（失敗なら nil）。
OP が生きていなければ取らず、取り終えた時点で死んでいれば呼ばない。
DROP-FAINT は `zellij-send--dump-screen-async' と同じ。"
  (when (zellij-send--op-live-p op)
    (with-current-buffer (zellij-send-op-buffer op)
      (zellij-send--dump-screen-async
       zellij-send--session (zellij-send--op-callback op callback)
       nil drop-faint))))

(defun zellij-send--op-keys (op bytes callback)
  "OP の黒板のペインに BYTES を送り、CALLBACK に終了コードを渡す。
OP が生きていなければ送らない。"
  (when (zellij-send--op-live-p op)
    (with-current-buffer (zellij-send-op-buffer op)
      (zellij-send--send-keys zellij-send--session bytes
                              (zellij-send--op-callback op callback)))))

(defun zellij-send--op-write-chars (op text callback)
  "OP の黒板のペインの入力欄に TEXT を打ち、CALLBACK に成功 t / 失敗 nil を渡す。
打てたら OP に印（`:typed'）を付ける。止めたときに入力欄を片付けるため。"
  (when (zellij-send--op-live-p op)
    (with-current-buffer (zellij-send-op-buffer op)
      (zellij-send--slash-write-chars
       zellij-send--session text
       (zellij-send--op-callback
        op (lambda (ok)
             (when ok (zellij-send--op-put op :typed t))
             (funcall callback ok)))))))

;;; スラッシュコマンド（Claude Code の /コマンド全部）

;;;; ペインとのやりとり

(defun zellij-send--slash-write-chars (session text callback)
  "SESSION の対象ペインに TEXT を `write-chars' で打ち込む。
`paste' ではなく `write-chars' を使うのは補完メニューを開かせるため
（paste されたテキストではメニューが出ない。2026-07-29 実測）。
CALLBACK には成功 t / 失敗 nil を渡す。"
  (zellij-send--zellij-async
   (append (list "--session" session "action" "write-chars")
           (zellij-send--pane-args)
           (list "--" text))
   (lambda (exit) (funcall callback (zerop exit)))))

;;; AskUserQuestion（選択肢プロンプト）への回答

(defvar-local zellij-send--askq-keys-auto nil
  "質問の自動起動でキー透過モードに入ったなら non-nil。
質問が画面から消えたときに自動で抜けるのはこの場合だけ。
ユーザーが `C-c C-t' で自分で入れたモードは勝手に切らない。")

;;; キー透過モード

;; `*ai-SESSION*' バッファには subscribe 経由でペインの生画面が 26〜40 ms 遅れで
;; 映っている。つまり「見る」側は既に完成しているので、足りないのは「打つ」側だけ。
;; このモードを有効にすると、矢印・Enter・Space・Tab・Esc・印字文字を
;; バッファ編集ではなく `zellij-send--send-keys' でペインへ流す。
;; AskUserQuestion の選択肢・権限ダイアログ・`/model' の選択など、
;; **画面の中身を解釈せずに**あらゆる TUI を Emacs から操作できる。
;;
;; 有効中はバッファを read-only にする。誤ってバッファを編集すると
;; `buffer-modified-p' が真になり、自動更新が抑止されて画面が固まったように
;; 見えるため（`zellij-send--update-buffer' の抑止条件）。

(defvar-local zellij-send--keys-saved-read-only nil
  "キー透過モードに入る前の `buffer-read-only' の値を (VALUE) の形で持つ。
入っていないときは nil。リストに包むのは、有効化が重なったときに
自分で立てた t を「元の値」として上書きしないため。")

(defun zellij-send--keys-send (bytes)
  "BYTES をペインへ送る。キー透過モード用の薄いラッパ。"
  (zellij-send--assert-session)
  (zellij-send--send-keys
   zellij-send--session bytes
   (lambda (exit)
     (unless (zerop exit)
       (message "キー送信に失敗しました (exit: %d)" exit)))))

(defun zellij-send--keys-define (map key bytes)
  "MAP の KEY に BYTES を送るコマンドを割り当てる。"
  (define-key map (kbd key)
              (lambda ()
                (interactive)
                (zellij-send--keys-send bytes))))

(defun zellij-send-keys-self-insert ()
  "押した印字文字をそのままペインへ送る。
`self-insert-command' の差し替え先。マルチバイト文字も送れるよう
UTF-8 のバイト列に分解してから送る。"
  (interactive)
  (let ((bytes (string-to-list (encode-coding-string (string last-command-event)
                                                     'utf-8))))
    (zellij-send--keys-send bytes)))

(defvar zellij-send-keys-mode-map
  (let ((map (make-sparse-keymap)))
    ;; 矢印は CSI シーケンス（↑ = ESC [ A）。1 回の write にまとめて送る
    (zellij-send--keys-define map "<up>"    '(27 91 65))
    (zellij-send--keys-define map "<down>"  '(27 91 66))
    (zellij-send--keys-define map "<right>" '(27 91 67))
    (zellij-send--keys-define map "<left>"  '(27 91 68))
    (zellij-send--keys-define map "C-p"     '(27 91 65))
    (zellij-send--keys-define map "C-n"     '(27 91 66))
    (zellij-send--keys-define map "C-f"     '(27 91 67))
    (zellij-send--keys-define map "C-b"     '(27 91 68))
    (zellij-send--keys-define map "RET"     '(13))
    (zellij-send--keys-define map "TAB"     '(9))
    (zellij-send--keys-define map "<backtab>" '(27 91 90))
    (zellij-send--keys-define map "<escape>" '(27))
    (zellij-send--keys-define map "DEL"     '(127))
    (define-key map [remap self-insert-command] #'zellij-send-keys-self-insert)
    (define-key map (kbd "C-c C-t") #'zellij-send-keys-mode)
    (define-key map (kbd "C-g")     #'zellij-send-keys-quit)
    map)
  "キー透過モードのキーマップ。ここにあるキーはペインへ送られる。")

(define-minor-mode zellij-send-keys-mode
  "有効な間、キー入力を zellij ペインへそのまま送る。
選択肢の上下移動 (↑↓)、決定 (RET)、複数選択のトグル (SPC)、
中止 (ESC)、数字キーなどが Emacs バッファではなくペインに届く。
`C-c C-t' か `C-g' で抜ける。"
  :lighter " →zellij"
  :keymap zellij-send-keys-mode-map
  (if zellij-send-keys-mode
      (progn
        ;; `define-minor-mode' はこの本体より先に変数を t にするため、
        ;; セッションが無いときは自分で false に戻してから抜ける
        (unless zellij-send--session
          (setq zellij-send-keys-mode nil)
          (user-error "zellij-send バッファ外では使えません"))
        (unless zellij-send--keys-saved-read-only
          (setq zellij-send--keys-saved-read-only (list buffer-read-only)))
        (setq buffer-read-only t)
        (message "キー透過モード ON（↑↓ 選択 / RET 決定 / SPC トグル / C-c C-t で解除）"))
    (when zellij-send--keys-saved-read-only
      (setq buffer-read-only (car zellij-send--keys-saved-read-only)
            zellij-send--keys-saved-read-only nil))
    ;; 手で抜けたら「自動で入った」印も落とす。次に自分で入れ直したモードを
    ;; 質問が消えた拍子に勝手に切らないため
    (setq zellij-send--askq-keys-auto nil)
    (message "キー透過モード OFF")))

(defun zellij-send-keys-quit ()
  "キー透過モードを抜ける。"
  (interactive)
  (zellij-send-keys-mode -1))

;;; エントリポイント

(defun zellij-send--run-in-session-async (session dir command callback)
  "SESSION に新しいペインを作って COMMAND（文字列）を起動する。
DIR はペインの作業ディレクトリ。成功したら pane-id（例: \"terminal_2\"）を、
失敗したら nil を CALLBACK に渡す。attach クライアントは不要（zellij 0.44+）。"
  (let ((out-buf (generate-new-buffer " *zellij-run*"))
        (err-buf (generate-new-buffer " *zellij-run-err*"))
        (process-environment (zellij-send--process-environment))
        (default-directory (zellij-send--process-directory)))
    (make-process
     :name "zellij-run"
     :buffer out-buf
     :stderr err-buf
     :noquery t
     :command (append (list zellij-send-executable "--session" session
                            "run" "--cwd" dir "--name" command "--")
                      (split-string command))
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((out (with-current-buffer out-buf (buffer-string))))
           (ignore-errors (kill-buffer out-buf))
           (ignore-errors (kill-buffer err-buf))
           (funcall callback
                    (and (zerop (process-exit-status proc))
                         (string-match "terminal_[0-9]+" out)
                         (match-string 0 out)))))))))

;;; セッションの拡幅（一瞬だけ attach する）

;; 背景セッションは 50 桁 × 48 行に固定され、COLUMNS / LINES では変えられない
;; （実測。CLAUDE.md「背景セッションの大きさ」参照）。唯一効くのが、目的の
;; 大きさの pty を持つクライアントで一瞬 attach して detach する方法。
;; サイズは detach 後も残り、あとから `zellij run' で足したペインも継承する。
;;
;; **このパッケージは attach クライアント（eat）起因のフリーズが解消できず
;; eat を全廃した経緯がある。** 復活させるにあたって以下を必ず守ること:
;; 1. 全面非同期。同期呼び出しを一切挟まない
;; 2. 出力を捨てるフィルタを必ず置く。Emacs が pty を読まないと zellij サーバが
;;    クライアントへの書き込みでブロックし、セッション全体が入力不可になる
;;    （旧デッドロックの原因はこれ）
;; 3. detach に失敗しても必ずプロセスを殺す。キーバインドを変更している環境では
;;    Ctrl+o d が効かない
;;
;; ターミナルから attach すると、セッションはその端末の大きさに縮み、
;; **detach しても縮んだまま残る**（2026-10-23 実測、zellij 0.45.1。200×80 に
;; 広げたセッションに 100×30 の端末で attach → detach すると、ペインは
;; 28 行 × 100 桁のまま）。黒板には zellij が描いている行しか届かないので、
;; 遡れる量がその端末の行数に減る。端末が繋がっている間は、zellij が
;; いちばん小さいクライアントに合わせるので広げられない。切れた後に監視が
;; 広げ直す（`zellij-send--restore-session-size'）。

(defvar zellij-send--resizing-sessions nil
  "拡幅の attach が走っているセッション名のリスト。二重に attach しないため。")

(defvar-local zellij-send--resize-tried nil
  "この黒板のセッションを最後に広げ直そうとしたときの大きさ (COLS . ROWS)。
広げても変わらなかったセッションに、監視のたびに attach し続けないため。")

(defconst zellij-send--session-chrome-rows 2
  "既定のレイアウトでセッションの行数のうち端末ペインに使われない行数。
タブバーとステータスバーの 1 行ずつ（2026-10-23 実測、zellij 0.45.1）。")

(defun zellij-send--session-shrunk-p (extent size tried)
  "端末ペインの範囲 EXTENT (COLS . ROWS) のセッションを SIZE に広げ直すべきなら non-nil。
EXTENT は `zellij-send--parse-terminal-extent' の値で、バーの行
（`zellij-send--session-chrome-rows'）を含まない。どちらかの向きで SIZE より
小さく、かつ TRIED（前回広げようとしたときの EXTENT）と違うとき。TRIED と
同じなら広げても変わらなかったので繰り返さない。バーの少ないレイアウトでは
数行縮んでも気付かないが、余計に attach するよりよい。"
  (and extent size
       (or (< (car extent) (car size))
           (< (+ (cdr extent) zellij-send--session-chrome-rows) (cdr size)))
       (not (equal extent tried))))

(defun zellij-send--restore-session-size (session)
  "縮んだままの SESSION を `zellij-send-session-size' に広げ直す。
カレントバッファ（SESSION の黒板）から呼ぶ。`list-panes --all' で大きさを見て
（`zellij-send--parse-terminal-extent'）、小さければ `list-clients' で
attach しているクライアントが居ないことを確かめてから広げる。
読めなかったとき・ペインの操作（`zellij-send-op'）中・拡幅中は何もしない。"
  (let ((size zellij-send-session-size)
        (buf (current-buffer)))
    (when (and zellij-send-restore-session-size size zellij-send--pane-id
               (not (zellij-send--op-current))
               (not (member session zellij-send--resizing-sessions)))
      (zellij-send--zellij-output-async
       session '("action" "list-panes" "--all")
       (lambda (out)
         (let ((extent (and out (zellij-send--parse-terminal-extent out))))
           (when (and (buffer-live-p buf)
                      (zellij-send--session-shrunk-p
                       extent size (buffer-local-value 'zellij-send--resize-tried buf)))
             (zellij-send--zellij-output-async
              session '("action" "list-clients")
              (lambda (out)
                ;; 失敗（nil）を 0 件と読まない。端末が繋がっていれば広げられない
                (when (and (buffer-live-p buf)
                           (eql (and out (zellij-send--parse-client-count out)) 0)
                           (not (zellij-send--op-current buf))
                           (not (member session zellij-send--resizing-sessions)))
                  (with-current-buffer buf
                    (setq zellij-send--resize-tried extent))
                  (zellij-send--resize-session session)))))))))))

(defun zellij-send--resize-session (session &optional callback)
  "SESSION を `zellij-send-session-size' の大きさに広げる。
その大きさの pty を持つクライアントで一瞬 attach し、detach して返る。
終わったら CALLBACK を呼ぶ（拡幅した場合 t、無効なら nil）。

`zellij-send-session-size' が nil なら何もせず CALLBACK を呼ぶ。"
  (let ((size zellij-send-session-size))
    (if (not size)
        (when callback (funcall callback nil))
      (let* ((cols (car size))
             (rows (cdr size))
             (process-environment
              (append (list (format "COLUMNS=%d" cols)
                            (format "LINES=%d" rows))
                      (zellij-send--process-environment)))
             (default-directory (zellij-send--process-directory))
             (finished nil)
             detach-timer watchdog proc)
        (setq proc
              (make-process
               :name (format "zellij-resize-%s" session)
               :buffer nil
               :noquery t
               :connection-type 'pty
               :command (list zellij-send-executable "attach" session)
               ;; 出力は捨てるが、フィルタは必ず置く（上記 2）
               :filter #'ignore
               :sentinel
               (lambda (p _event)
                 (when (and (not finished)
                            (memq (process-status p) '(exit signal)))
                   (setq finished t)
                   (setq zellij-send--resizing-sessions
                         (delete session zellij-send--resizing-sessions))
                   (when (timerp detach-timer) (cancel-timer detach-timer))
                   (when (timerp watchdog) (cancel-timer watchdog))
                   (when callback (funcall callback t))))))
        ;; 起動できてから印を付ける（sentinel は終了時に外す）
        (push session zellij-send--resizing-sessions)
        ;; pty の大きさを与える。zellij は接続時にこれを読み、
        ;; 後から変わっても SIGWINCH で拾う
        (ignore-errors (set-process-window-size proc rows cols))
        ;; 繋がってサイズが伝わるのを待ってから detach（Ctrl+o d）
        (setq detach-timer
              (run-at-time zellij-send-resize-detach-delay nil
                           (lambda ()
                             (when (process-live-p proc)
                               (ignore-errors
                                 (process-send-string proc "\C-od"))))))
        ;; detach が効かなくても必ず落とす（上記 3）
        (setq watchdog
              (run-at-time zellij-send-resize-timeout nil
                           (lambda ()
                             (when (process-live-p proc)
                               (delete-process proc)))))))))

(defun zellij-send-resize-session ()
  "このバッファのセッションを `zellij-send-session-size' の大きさに広げる。
背景セッション（`[New]' で作ったもの）は 50 桁しかないため、既に作って
しまったセッションを後から広げるのに使う。
ターミナルから作ったセッションはそのターミナルの幅なので通常は不要。"
  (interactive)
  (zellij-send--assert-session)
  (unless zellij-send-session-size
    (user-error "zellij-send-session-size が nil です"))
  (let ((session zellij-send--session))
    (message "セッション [%s] を %d 桁 × %d 行に広げています..."
             session (car zellij-send-session-size) (cdr zellij-send-session-size))
    (zellij-send--resize-session
     session
     (lambda (resized)
       (message "セッション [%s] の拡幅%s" session
                (if resized "が完了しました" "は行いませんでした"))))))

(provide 'zellij-send-core)

;;; zellij-send-core.el ends here
