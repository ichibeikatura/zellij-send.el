# CLAUDE.md

このファイルは、このリポジトリでコードを扱う際の Claude Code へのガイダンスです。

## プロジェクト概要

Emacs から zellij セッション上の AI エージェント（主に Claude Code）に日本語テキストを送る Emacs パッケージ。
`M-x zellij-send` でセッションを選択し、専用バッファ（`*ai-セッション名*`）で入力・確認・返信を行う。
このパッケージは 2 つの要素で成り立つ:
- *ai-SESSION* バッファ（黒板）: ユーザーが入力するための主インターフェース
- zellij セッション本体: detached（attach クライアントなし）でバックグラウンドで動く実体

**attach クライアントは不要**（zellij 0.44+ で実機検証済み）。新規セッションは
`zellij attach --create-background` で detached のまま作り、`zellij run` で claude を
起動して返る pane-id（`terminal_N`）を保持し、以後すべての送受信を `--pane-id` 指定で行う。
focused pane への送信（pane-id 指定なし）はクライアントがいないと届かないため、
pane-id 不明の既存セッションに送る場合のみ使う（ターミナル側で attach していれば動く）。
かつては eat による attach を必須としていたが、eat 連携が原因のフリーズが解消できず全廃した。

## 開発環境

- Emacs 31、`lexical-binding: t`
- 依存: `transient` 0.4以上（必須）、`markdown-mode`（オプション）
- zellij **0.44 以上**（dump-screen の STDOUT 出力・`--pane-id` 指定に依存）
- パッケージ管理: elpaca 想定

## ファイル構造

| ファイル | 役割 |
|---|---|
| `zellij-send.el` | パッケージ本体（全機能） |
| `zellij-send-dashboard.el` | セッション一覧ダッシュボード（本体に依存。逆依存は禁止） |
| `test/zellij-send-test.el` | ert テスト（zellij を必要としない純粋な関数のみ） |
| `CLAUDE.md` | 本ドキュメント |
| `README.md` | ユーザー向けドキュメント |
| `LICENSE` | GPL v3 |

## アーキテクチャ

```
Emacs バッファ (*ai-SESSION*)  [zellij-send--pane-id を保持]
  ├─ 入力: C-c C-c → zellij-send--send → zellij action paste/write 13（--pane-id 指定）
  ├─ 表示: zellij action dump-screen → STDOUT 直読み → バッファ更新（非同期 / make-process + sentinel）
  ├─ 自動受信: zellij subscribe の常駐プロセス（NDJSON）＋ Stop フック (emacsclient)
  ├─ ログ: Stop フックが transcript から assistant 出力を .zellij-send/claude-log.md に追記
  └─ UI: transient メニュー (C-c C-a)
```

### zellij コマンドの呼び出し方針

- **すべての zellij 呼び出しは非同期**（`make-process` + sentinel）。同期 `call-process` は禁止（Emacs の UI をブロックしフリーズの温床になる）
- 引数は個別の文字列として渡し、**シェル文字列結合は行わない**（コマンドインジェクション防止）。ユーザーテキストの直前に `--` を置き、`-` 始まりのテキストがオプション扱いされるのを防ぐ
- 汎用ヘルパー: `(zellij-send--zellij-async args &optional callback)` — callback に exit code を渡す
- 送信: `(zellij-send--send session text &optional callback)` — paste → 成功後に write 13 を sentinel で連鎖。callback には成功 t / 失敗 nil。カレントバッファの `zellij-send--pane-id` を呼び出し時に取り込むため、**必ず対象バッファをカレントにして呼ぶ**（返信バッファには pane-id をコピーしてある）
- スクリーン取得: `(zellij-send--dump-screen-async session callback)` — STDOUT 直読み（zellij 0.44+、tmpfile 不使用）。コールバックは要求元バッファをカレントにした状態で呼ばれる
- ペイン起動: `(zellij-send--run-in-session-async session dir command callback)` — `zellij run` の STDOUT から pane-id を抽出して callback に渡す

**送信後の後処理は成功コールバック内で行う**: バッファクリア（`zellij-send-send`）や返信バッファのクローズ（`zellij-send--reply-send`）は送信成功後に実行し、失敗時に入力テキストを失わないようにする。

**sentinel の中でミニバッファ入力をしない**: sentinel / プロセスフィルタは quit が抑止された状態で走ることがあり、その中で `completing-read` や `read-directory-name` を呼ぶと C-g が効かない・入力が壊れる。非同期結果を受けてユーザーに質問する場合は `(run-at-time 0 nil #'FUNC ARGS)` で sentinel を抜けてから行う（`zellij-send` → `zellij-send--select-session` がこの形）。

**セッション一覧のパース**: `zellij-send--parse-sessions` は `NAME [Created ...]` 形式の行だけを採用し、EXITED セッションと「セッション 0 件」の案内文（`No active zellij sessions found.`）を除外する。先頭トークンを無条件に拾うと案内文から `No` というセッション名が生まれる。

### Enter キー送信の注意点

テキストに `\n` を含めても Enter にならない。必ず 2 ステップに分ける:
```
zellij action paste --pane-id terminal_N -- "テキスト"
zellij action write --pane-id terminal_N -- 13    ; 0x0D = CR = Enter
```

**本文は `write-chars` ではなく `paste` で送る**（2026-07-28 実測で決定）:

- `write-chars` は改行を LF のまま渡す。**Claude Code は LF では送信を確定しない**
  （実測: 3 行を `write-chars` で送っても入力欄に 3 行入るだけで送信されない）ため
  Claude Code 相手なら壊れないが、**シェルは LF で確定する**（実測: zsh ペインに 2 行送ると
  1 行目が実行された）。`zellij-send-default-command` は変更可能なので防御的に `paste` を使う
- `paste` は**受け手が bracketed paste を有効にしている時だけ**マーカーで包む。
  有効にしていないペイン（canonical mode の `cat` 等）には素の文字列が渡るので、
  `[200~` がリテラルで現れる心配はない。切替用の defcustom は不要
- **`ESC[200~` を手で組んではいけない**。単独の
  `zellij action write -- 27 91 50 48 48 126` は zellij の入力パーサに食われてペインに届かない
  （実測で確認。`ESC[200~Q` のように余分なバイトを足すと素通しされる）。
  全バイトを 1 回の `write` にまとめれば届くが、日本語は 1 文字 3 バイトなので argv が肥大する
- 副作用: 長文は Claude Code の入力欄で `[Pasted text #1 +59 lines]` に畳まれる
  （実測 60 行）。内容は完全に送信されるが、`*ai-SESSION*` バッファには
  本文ではなくプレースホルダが映る
- `paste` は zellij 0.44.0 で追加（#4817）。必要バージョンの引き上げは不要

### ANSI エスケープの除去

`zellij-send--strip-ansi` で 4 段階除去する。**順序が意味を持つ**ので入れ替えないこと:

```elisp
"\033\\][^\a\033]*\\(?:\a\\|\033\\\\\\)"  ; 1. OSC（BEL または ST 終端）
"\033[PX^_][^\033]*\033\\\\"              ; 2. DCS / SOS / PM / APC（ST 終端）
"\033\\[[0-9;?]*[A-Za-z]"                 ; 3. CSI
"\033[ -/]+[0-~]"                         ; 4a. nF エスケープ（ESC ( B など）
"\033."                                   ; 4b. その他の 2 文字（ESC =、ESC 7）
```

最後の 2 文字規則を先に走らせてはいけない。`ESC ]` の 2 文字だけを食って
`0;title` とベル文字が本文に残る。同じ理由で `ESC ( B` は 3 バイトなので
nF 規則が必要（2 文字規則だけだと `B` が残る。テストで検出した実バグ）。

**どこで効いているか**（2026-07-28 実測）:

- `list-sessions` の出力には**今もカラーコードが入る**（`ESC[32;1m...`）。ここは現役
- `dump-screen` は `--ansi` を付けない限り**平文を返す**（実測: ESC を含む行が 0）。
  こちらは保険として通しているだけ

### テスト

```sh
emacs -Q -batch -L . -l ert -l test/zellij-send-test.el -f ert-run-tests-batch-and-exit
```

zellij を必要としない純粋な関数だけを対象にする（`--strip-ansi` / `--parse-sessions`）。
zellij を叩く経路は使い捨てセッションを作って手で確認する。

## コーディング規約

### 命名規則

| パターン | 用途 |
|---|---|
| `zellij-send-FOO` | ユーザー向け `M-x` コマンド、`defcustom`、`defvar` |
| `zellij-send--FOO` | 内部関数・変数（公開しない） |
| `zellij-send--FOO` (defvar-local) | バッファローカル状態 |

### defcustom の流儀

```elisp
(defcustom zellij-send-FOO default-value
  "日本語の説明。"
  :type 'string   ; または 'number 'boolean など
  :group 'zellij-send)
```

### バッファローカル変数

`defvar-local` で宣言し、`setq-local` で設定する:
```elisp
(defvar-local zellij-send--session nil "...")
;; 設定時:
(setq-local zellij-send--session session)
```

### インタラクティブ関数のガード

バッファ外から呼ばれた場合は `user-error` で即終了:
```elisp
(defun zellij-send-FOO ()
  "説明。"
  (interactive)
  (unless zellij-send--session
    (user-error "zellij-send バッファ外では使えません"))
  ...)
```

### エラーメッセージ・メッセージ

日本語で書く。`user-error` はユーザー操作ミス、`error` はプログラムエラー。

### セクション構成（zellij-send.el の順序）

```
;;; defgroup / defcustom
;;; defvar-local
;;; セッション一覧の取得
;;; バッファ管理
;;; 送信
;;; スクリーンダンプ
;;; プロンプト検出・ハイライト
;;; バッファ更新（共通処理）
;;; 自動受信（zellij subscribe）
;;; Claude Code コマンド
;;; インタラクティブコマンド
;;; 返信バッファ
;;; Transient メニュー
;;; メジャーモード
;;; Stop フックハンドラ
;;; エントリポイント
```

## ダッシュボード（zellij-send-dashboard.el）

`M-x zellij-send-dashboard` / メニュー `d`。全セッションを tabulated-list で一覧し、
要対応順（選択待ち → 完了 → 作業中 → 待機）に並べる。

- **依存は一方向**: dashboard → 本体。本体は `zellij-send-dashboard` を require せず、
  メニューの `d`（`zellij-send-open-dashboard`）が `fboundp` / `require ... noerror` で
  遅延ロードする。本体からダッシュボードのシンボルを参照しないこと
- **状態は本体に持たせない**: 各セッションバッファの内容から毎回算出する
  （本体の状態フラグはモードライン撤去時に削除済み）
  - 作業中: スピナー行（`zellij-send-dashboard-working-regexp`、既定
    `esc to interrupt`）がある **か**、画面が
    `zellij-send-dashboard-active-window` 秒以内に変化した。
    **Claude Code は本文を流している間スピナー行を出さない**（実機で確認）ため、
    スピナーだけで判定すると回答中を「待機」と誤表示する。画面が動いていること
    自体を処理中の証拠として使う
  - 完了: 作業中だったセッションからスピナーが消えた瞬間。そのバッファが
    ウィンドウに表示された時点で解除
  - 選択待ち: `zellij-send--detect-prompt`
- **zellij を追加で呼ばない**: 表示は本体が subscribe で受けた結果（バッファ内容と
  `zellij-send--last-change-time`）を読むだけ
  （例外は 15 秒ごとのセッション検出。「セッションの検出」節を参照）

### キーと更新（Emacs の作法）

- `g` が更新。`revert-buffer-function` も `zellij-send-dashboard-refresh` に
  差し替える。既定の `tabulated-list-revert` は `tabulated-list-entries` を
  作り直さないため、`M-x revert-buffer` やマウス経由だと使用状況の再取得を
  含む更新が走らない
- `?` が `zellij-send-dashboard-help`（`*zellij-dashboard-help*` を
  `with-help-window` で出す。`q` で閉じる）。**キー一覧は
  `zellij-send-dashboard--keys` に書き、ヘルプはそこから描く**。
  ヘルプは各行を実際のキーマップと突き合わせ、食い違えば「← 未割り当て」と
  印を付けるので、キーを足したらこの表にも足すこと
- **`header-line-format` にキーヒントを置いても無駄**。直後の
  `tabulated-list-init-header` が列見出しで上書きする（かつてこれで
  ヒントが表示されていなかった）
### Remote Control の QR（ダッシュボードの `r`）

`/remote-control` をペインに送り、Claude Code が描く QR を dump-screen で取り込む
（QR 生成器は不要）。実機検証で判明した注意点:

- **メニューはカーソル移動量を「行数」で数えてはいけない**。項目の説明文が折り返して
  複数行になるため、行数で数えると `Show QR code` を通り越して
  `Disconnect this session` を選んでしまう（実際に踏んだ）。項目ラベルの並びで数え、
  さらに **Enter の前に `❯` が `Show QR code` にあることを確認する**
  （`zellij-send-dashboard--qr-confirm-and-enter`）
- **接続に 10 秒以上かかる**。固定待ちではなくタイムアウト付きポーリングにする
  （`zellij-send-dashboard--wait-for-screen`）
- 取り込み後は必ず `Esc`（バイト 27）を送ってペインをプロンプトに戻す。
  メニューに留まると以後の送信が壊れる
- **QR は文字ではなく SVG 画像で描く**。半角ブロック（█=上下 / ▀=上 / ▄=下）から
  モジュール行列を復元し、白地に黒＋静穏帯 4 モジュールで描画する
  （`zellij-send-dashboard--qr-matrix` / `--qr-image`）。文字のまま貼るとフォントの
  字形に左右されて読み取れない（M PLUS 等でブロック字形が行高を超える）。
  SVG が使えない環境向けにテキスト版も残し、その場合は `char-width-table` を
  バッファローカルに差し替えてブロック文字を 1 桁にする（既定は 2 桁＝
  East Asian Ambiguous で、そのままだと横に伸びる）

**フォント依存の描画は避ける**: 使用状況バーも同じ理由でブロック文字をやめ、
空白に `:background` を付けて描くのが既定（`zellij-send-dashboard-usage-bar-style`
の `face`）。グリフに頼らないのでフォントの字形に影響されない。
- ローカルセッションを claude.ai に露出させる操作なので `yes-or-no-p` で必ず確認し、
  待機中のセッションに限る（作業中のペインに文字を打ち込まない）

### 使用状況（/usage 相当）

`/usage` は Claude Code の TUI 内でしか実行できず、`claude` CLI にも `usage`
サブコマンドは無い（transcript にもレート制限は残らない）。取得できる公式ルートは
**statusLine コマンドの stdin JSON だけ**:

```
rate_limits.five_hour.{used_percentage, resets_at}   ; resets_at は Unix 秒
rate_limits.seven_day.{used_percentage, resets_at}
context_window.used_percentage
```

そのため statusLine フック側で JSON をキャッシュに保存し（README 参照）、
`zellij-send-dashboard--read-usage` はそれを読むだけにする。**ダッシュボードから
claude を起動したりペインに `/usage` を打ち込んだりしないこと**（セッションに割り込む）。
キャッシュは動作中の Claude Code セッションだけが更新するため、表示には
mtime からの経過時間を必ず添える（古い数字を最新に見せない）。

am/pm と月名は `format-time-string` の `%p` / `%b` がロケール依存（日本語環境では
「午後」「 7」になる）ため自前で組み立てる。

## バッファの設計思想

`*ai-SESSION*` バッファは「黒板」として使う:
- 固定ヘッダなし（バッファ全体がコンテンツ）
- セッション情報は `header-line-format` に表示
- ユーザーが編集中（`buffer-modified-p` = t）は自動更新で上書きしない
- `zellij-send--user-cleared` フラグ: ユーザーが意図してクリアした場合に Stop フック・自動更新の上書きを防ぐ
- 更新時は point と `window-start` を復元する（`zellij-send--update-buffer`）。毎回 `point-min` に飛ばすと更新のたびに読んでいる位置が失われる
- **モードライン通知は持たない**（2026-07-27 撤去）。`global-mode-string` への `:eval` 登録は再描画のたびに全バッファを走査するうえ、状態表示は別途 `zellij-send-dashboard.el` で扱う。作業中/完了の検知（`zellij-send-ready-regexp` / `--is-ready` / `--notifying` / `--was-busy`）も併せて削除済み
- 数字キー（`1`/`2`/`3`）の即送信も撤去。プロンプト表示後にバッファへ本文を書くと数字が誤送信されるため。選択肢の送信は `C-c C-a` → `n`（`zellij-send-reply-number`）。プロンプト行のハイライトは維持

## 自動受信（zellij subscribe）

セッションごとに `zellij subscribe` の常駐プロセスを 1 本持つ。**2 秒ポーリングは廃止**
（`zellij-send-poll-interval` / `--poll` / `--start-polling` / `--stop-polling` を削除）。

```sh
zellij --session NAME subscribe --pane-id terminal_N --format json
```

イベントは NDJSON（1 行 1 オブジェクト）:

```json
{"event":"pane_update","is_initial":true,"pane_id":"terminal_1","scrollback":null,"viewport":["行1","行2"]}
```

### 実測で分かった注意点（2026-07-28 / zellij 0.44.3）

- **`--pane-id` は必須**。pane-id 不明なら `--detect-pane-async` で先に特定してから張る
  （`zellij-send--subscribe-ensure` がこれをやる）
- **`viewport` は差分ではなく毎回フル**の行配列。`string-join` して既存の
  `zellij-send--update-buffer` にそのまま渡せる。**再接続時に `dump-screen` で
  取り直す必要はない**（初回配信がフルなので勝手に整合する）
- **1 イベント約 8 KB**で複数回に分かれて届く。プロセスフィルタは**行単位の
  バッファリングが必須**（`zellij-send--subscribe-pending`）
- **セッションが消えても subscribe は終了しない**。`delete-session --force` の後も
  17 秒以上生き続けた。**プロセスの死を検知手段にできない**。`kill-buffer-hook` で
  確実に殺すのが唯一の後始末（`zellij-send--subscribe-stop`）
- **存在しないセッションを指定すると終了コード 0** のまま何も流れない。終了コードで
  成否を判定できないので、`zellij-send-subscribe-initial-timeout`（既定 15 秒）以内に
  初回イベントが来なければ失敗とみなす（存在しない pane-id は exit 2）
- 意図的に止めるときは **sentinel を `ignore` に差し替えてから** `delete-process` する。
  そうしないと自前の再接続が走る

### 性能（実測）

| | subscribe | 旧ポーリング |
|---|---|---|
| アイドル 20 秒 | イベント 1 件（初回配信のみ） | dump-screen プロセス 10 個 |
| 定常状態のプロセス数 | セッションあたり 1 本（3 セッションで 3 本を確認） | 2 秒ごとに生成 |
| 画面変化 → バッファ反映 | **26〜40 ms** | 最大 2000 ms |
| 応答ストリーミング中 | 2.1 events/sec | — |

### 更新抑止と変化時刻

`buffer-modified-p` が真、または `zellij-send--user-cleared` が真のときはバッファを
書き換えない。ただし **`zellij-send--last-change-time` は抑止中も更新し続ける**。
ダッシュボードの「作業中」判定はこれを見るので、編集中の変化を取りこぼさない。

## 自動受信・出力ログ（Stop フック）

Claude Code 停止時に `~/.claude/hooks/stop-zellij-send.sh` が 2 つの処理を行う:
1. フック stdin の JSON から `transcript_path` と `cwd` を取り、最新の assistant 出力を
   `CWD/.zellij-send/claude-log.md`（`zellij-send-log-file` と対応）に時刻付きで追記（python3 使用）
2. `emacsclient` → `zellij-send--on-claude-stop` でバッファを更新。`;;;###autoload` が必須

ログは `C-c C-a` → `l`（`zellij-send-open-log`）で開く。

## スクリーン取得の限界（調査済み・再調査不要）

2026-07-28 に zellij 0.44.3 + Claude Code v2.1.220 で実測した結果。
**同じ調査を繰り返さないこと。**

### `--full` は Claude Code に効かない

`dump-screen --full` はスクロールバックまで取るオプションだが、
**alt-screen の TUI には仕様上スクロールバックが無い**ため viewport と同じ内容しか返らない。

対照実験（claude に 1〜40 を 1 行ずつ列挙させ、28 行のペインで比較）:

| 対象 | viewport | `--full` |
|---|---|---|
| claude ペイン（alt-screen） | 28 行（22〜40 のみ） | **28 行。同一。1〜21 は取れない** |
| 通常ペイン（`seq 1 200`） | 27 行 | 200 行（1 から全部） |

`--full` 自体は正常。**流れて消えた Claude の出力は `zellij-send-log-file`
（Stop フックが transcript から追記）で読む**。これが唯一の正しい経路。
`zellij-send-show-response` に `--full` を付けてあるのは、alt-screen でない
コマンドを `zellij-send-default-command' にした場合のためだけ。

### alt-screen リサイズ由来の表示崩れ（zellij#5311）は再現しない

<https://github.com/zellij-org/zellij/issues/5311> の「リサイズすると dump-screen が
見えていない行まで返してステータス領域が二重に出る」現象は **0.44.3 では再現しなかった**。
拡大（320×80）・縮小（100×24）・会話履歴あり・リサイズ 3 往復・`--full` 併用の
いずれでも、ダンプ行数はペイン行数と一致しステータス行の重複も無し。

## セッションの終了（zellij-send-quit）

**エージェントが終了してもセッションは消えない**（2026-07-28 実測）。`/exit` で claude が
落ちてもペインは残り、`list-sessions` にセッションが居続ける。したがって
「セッションが消えるのを待つ」実装は必ずタイムアウトする。

終了の判定には **`zellij action list-panes --all` の `EXITED` 列**を使う:

```
TAB_ID TAB_POS TAB_NAME PANE_ID TYPE TITLE COMMAND CWD FOCUSED FLOATING EXITED X Y ROWS COLS
0 0 Tab #1 terminal_1 terminal claude claude - true false true 0 1 48 50
```

- 列は 2 個以上の空白区切りだが、**TITLE と COMMAND 自体に空白が入る**
  （例: `caffeinate -i -t 300`）。位置の決め打ちは禁止。`zellij-send--parse-pane-exited`
  はヘッダ行から `PANE_ID` と `EXITED` の列位置を求め、フィールド数がヘッダと
  一致しない行は読み飛ばす
- 判定できないときは `:unknown` を返し、**絶対に t を返さない**。t は
  「セッションを消してよい」の合図なので、誤検出が最も危険
- pane-id 不明のセッションでは `list-sessions` の消滅を見る（ターミナル側で
  閉じられた場合に効く）。`:timeout` を「0 件」と解釈しないこと
- 終了を検出したら結局 `delete-session --force` で消す（セッションは自然には消えない）。
  `zellij-send-quit-timeout`（既定 10 秒）を超えたら待つのをやめて同じ強制削除に落ちる

実測: アイドル状態の claude セッションなら **1.3 秒**で検出・削除できる（旧実装は固定 2 秒待ち）。

## 新規セッション作成

`zellij-send--create-new-session` のフロー（すべて非同期）:
1. `zellij attach --create-background NAME` — detached セッション作成（tty 不要）
2. `zellij-send--resize-session` — 一瞬 attach して 320×80 に広げる（下記）。
   **ペインを作る前**に行うこと。後から作るペインが拡幅後のサイズを継承する
3. 0.5 秒待って `zellij --session NAME run --cwd DIR --name CMD -- CMD` — claude ペインを起動
4. `zellij run` の STDOUT から pane-id（`terminal_N`）を抽出し、黒板バッファの
   `zellij-send--pane-id` に保存

### 背景セッションの大きさ（調査済み・再調査不要）

**`COLUMNS` / `LINES` を渡してもセッションの大きさは変わらない**（2026-07-28、
zellij 0.44.3 で実測）。かつて `zellij-send--process-environment` から
これを渡していたが、効果が無いことを確認したので削除した。**環境変数の経路を
復活させないこと**（`zellij-send-session-size` という名前は今も使っているが、
意味が「拡幅用クライアントの pty サイズ」に変わっている。下記参照）。

`ZELLIJ_SOCKET_DIR` で隔離したまっさらなサーバを立てて検証した結果:

| 条件 | 実測（rows cols） |
|---|---|
| 新規サーバ + `COLUMNS=320 LINES=80` | 48 50 |
| 新規サーバ + `COLUMNS=200 LINES=60` | 48 50 |
| 新規サーバ + COLUMNS/LINES なし | 48 50 |
| 稼働中サーバ + `COLUMNS=320 LINES=80` | 47 104 |

サーバ起動時であっても環境変数は見られていない。旧ドキュメントの
「未指定だと 25 桁 × 24 行」も誤り。実際は **50 桁 × 48 行**で、25 桁に見えたのは
50 桁を 2 ペインで分割していたため。CLI にも設定ファイルにも背景セッションの
既定サイズを決める項目は無く、浮動ペインの `--width` もビューポートに丸められる。

### 回避策（実装済み）: 一瞬だけ attach して広げる

唯一効くのが「目的の大きさの pty を持つクライアントで一瞬 attach して detach する」方法。
サイズは detach 後も残り、後から `zellij run` で足したペインも継承する。
`zellij-send--resize-session` がこれを行い、`[New]` の新規作成フローが
**ペインを作る前に**呼ぶ（`zellij-send-session-size`、既定 `(320 . 80)`）。
既存セッションは `M-x zellij-send-resize-session` で後から広げられる。

**このパッケージは attach クライアント（eat）起因のフリーズが解消できず eat を
全廃した経緯がある。** 触るときは以下を必ず守ること:

1. **全面非同期**。同期呼び出しを一切挟まない
2. **出力を捨てるフィルタ（`:filter #'ignore`）を必ず置く**。Emacs が pty を
   読まないと zellij サーバがクライアントへの書き込みでブロックし、セッション
   全体が入力不可になる。**旧デッドロックの原因はこれ**
3. **detach に失敗しても必ず殺す**。`zellij-send-resize-timeout`（既定 8 秒）の
   watchdog で `delete-process` する。キーバインドを変えている環境では
   `Ctrl+o d` が効かない

実測（2026-07-28）:

| 経路 | 結果 |
|---|---|
| 正常系（detach が効く） | 2.0 秒で完了。48×50 → **78×320**。プロセス残留なし |
| watchdog 経路（detach を送る前に強制 kill） | 4.0 秒で完了。**セッションは生存**し拡幅も有効（58×200）。残留なし |
| 新規作成フル経路 | 拡幅 → claude 起動 → pane-id 取得 → subscribe 開始まで通し |
| 拡幅後の送受信 | 送信 OK・subscribe に反映 OK・プロセス生存（デッドロックなし） |

なお**ターミナルから作ったセッションはそのターミナルの幅になる**（実測 209 桁）ので、
この問題は zellij-send が `[New]` で作った背景セッションに限る。
既存セッションのサイズは後から変えられない（作り直しが必要）。

## 既存セッションへの接続（pane-id の復元）

`zellij-send-attach-session-async` が、ユーザーに何も聞かずに黒板バッファを用意する:

- cwd: `zellij action dump-layout` の先頭 `cwd "..."`
- pane-id: `zellij action list-panes`（`PANE_ID  TYPE  TITLE` の表）から
  TYPE=terminal の行を拾い、TITLE が `zellij-send-default-command` と一致する
  ペインを優先。無ければ最初の端末ペイン

これにより **pane-id はバッファローカルでも復元できる**（Emacs 再起動後も
attach クライアント無しで送信できる）。`M-x zellij-send` の既存セッション選択と
ダッシュボードの自動接続（`zellij-send-dashboard-auto-connect` / `G`）は
どちらもこの関数を使う。ディレクトリを尋ねるのは新規セッション作成時だけ。

### セッションの検出（ダッシュボードの 2 本目のタイマー）

再描画タイマー（既定 3 秒、バッファを読むだけ）とは別に、
`zellij-send-dashboard-scan-interval`（既定 15 秒）の検出タイマーを持つ。
**`zellij` を呼ぶのはこちらだけ**。`zellij-send-dashboard--sync-sessions` が
`list-sessions` と突き合わせ、未接続セッションに接続し、消えたセッションの
バッファを kill する（`--prune-gone`）。守るべき点:

- **タイムアウト（`:timeout`）を「0 件」と解釈しない**。そのまま prune すると
  zellij が一時的に応答しないだけで全行が消える
- **編集中（`buffer-modified-p`）のバッファは kill しない**。書きかけの入力を失う
- `--scanning` フラグで多重起動を防ぐ（応答が 15 秒を超えても `zellij` を重ねない）
- ダッシュボードを閉じたら `--stop-timers` で両方止める
