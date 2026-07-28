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
| `CLAUDE.md` | 本ドキュメント |
| `README.md` | ユーザー向けドキュメント |
| `LICENSE` | GPL v3 |

## アーキテクチャ

```
Emacs バッファ (*ai-SESSION*)  [zellij-send--pane-id を保持]
  ├─ 入力: C-c C-c → zellij-send--send → zellij action paste/write 13（--pane-id 指定）
  ├─ 表示: zellij action dump-screen → STDOUT 直読み → バッファ更新（非同期 / make-process + sentinel）
  ├─ 自動受信: Stop フック (emacsclient) または ポーリング (run-at-time)
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

`list-sessions` / `dump-screen` の出力にはカラーコードが含まれる。`zellij-send--strip-ansi` で 2 段階除去:
```elisp
(replace-regexp-in-string "\033\\[[0-9;?]*[A-Za-z]" "" result)  ; CSI
(replace-regexp-in-string "\033." "" result)                      ; その他 ESC
```

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
;;; ポーリング
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
- **zellij を追加で呼ばない**: 表示は本体のポーリング結果（バッファ内容）を読むだけ
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
- ユーザーが編集中（`buffer-modified-p` = t）はポーリングで上書きしない
- `zellij-send--user-cleared` フラグ: ユーザーが意図してクリアした場合に Stop フック・ポーリングの上書きを防ぐ
- 更新時は point と `window-start` を復元する（`zellij-send--update-buffer`）。毎回 `point-min` に飛ばすと 2 秒ごとに読んでいる位置が失われる
- **モードライン通知は持たない**（2026-07-27 撤去）。`global-mode-string` への `:eval` 登録は再描画のたびに全バッファを走査するうえ、状態表示は別途 `zellij-send-dashboard.el` で扱う。作業中/完了の検知（`zellij-send-ready-regexp` / `--is-ready` / `--notifying` / `--was-busy`）も併せて削除済み
- 数字キー（`1`/`2`/`3`）の即送信も撤去。プロンプト表示後にバッファへ本文を書くと数字が誤送信されるため。選択肢の送信は `C-c C-a` → `n`（`zellij-send-reply-number`）。プロンプト行のハイライトは維持

## 自動受信・出力ログ（Stop フック）

Claude Code 停止時に `~/.claude/hooks/stop-zellij-send.sh` が 2 つの処理を行う:
1. フック stdin の JSON から `transcript_path` と `cwd` を取り、最新の assistant 出力を
   `CWD/.zellij-send/claude-log.md`（`zellij-send-log-file` と対応）に時刻付きで追記（python3 使用）
2. `emacsclient` → `zellij-send--on-claude-stop` でバッファを更新。`;;;###autoload` が必須

ログは `C-c C-a` → `l`（`zellij-send-open-log`）で開く。

## 新規セッション作成

`zellij-send--create-new-session` のフロー（すべて非同期）:
1. `zellij attach --create-background NAME` — detached セッション作成（tty 不要）
2. 0.5 秒待って `zellij --session NAME run --cwd DIR --name CMD -- CMD` — claude ペインを起動
3. `zellij run` の STDOUT から pane-id（`terminal_N`）を抽出し、黒板バッファの
   `zellij-send--pane-id` に保存

**セッションの大きさは環境変数で決まる**。zellij は tty が無いとき `COLUMNS` /
`LINES` を見て、無ければ **25 桁 × 24 行**という極端に狭いサイズになる。Emacs の
サブプロセスには tty も `COLUMNS` も渡らないため、放っておくと必ずこれを踏む。
Claude Code は自分でペイン幅に合わせて改行を入れて出力するので、狭いペインでは
本文が細切れに折り返されて読めない（実測: 25 桁）。`zellij-send-session-size`
（既定 `(320 . 80)`）を `zellij-send--process-environment` で `COLUMNS` / `LINES`
として渡して回避する。`TERM` と同じ経路なので、**両方ともここに集約する**こと。
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
