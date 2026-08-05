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

### セクション構成

`zellij-send.el` は `;;;` 見出しで区切る。現在の並びは
`grep "^;;; " zellij-send.el` で確認し、**新しい関数は既存の見出しの下に置く**
（末尾に足さない）。

## AskUserQuestion への回答（調査済み・再調査不要）

2026-07-29 に Claude Code v2.1.220 + zellij 0.44.3（320 桁の背景セッション）で
実測した画面仕様。**同じ調査を繰り返さないこと。**

```
←  ☐ 好きな色  ☒ 好きな果物  ✔ Submit  →   ← 質問タブ（☒ = 回答済み）

好きな果物はどれですか（複数選択可）？      ← 質問文

❯ 1. [ ] りんご                            ← ❯ = カーソル、[ ] = 複数選択
  定番。シャキシャキした食感。              ← 説明（折り返すことがある）
  2. [✔] みかん
  5. [ ] Type something                    ← 自由入力
     Submit
────────────────────────────
  6. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
```

- **数字キーが直接効く**。単一選択なら数字 1 つで即確定して次の質問へ自動で進み、
  複数選択なら数字がその選択肢のトグルになる（**カーソルは動かない**）。
  したがってカーソル移動量を数える必要が無い（折り返しで必ずずれる）。
  折り返しに強いので、**移動量を数える実装に書き換えないこと**
- ←/→ が質問タブの移動。Tab は前進のみでラップしない
- 複数選択の質問からは → で「Review your answers」へ直行できる
- **自由入力（Type something）にカーソルがある間は ←/→ が入力欄内のカーソル移動になり、
  タブ移動にならない**。この状態から確定するには ↓（直下は必ず `Submit` 行）→ Enter。
  ここを → で済ませようとして無限ループを踏んだ（数字キーが入力欄に打ち込まれ、
  ラベルが `自由入力テスト4444…` に育った）
- 本文は `paste` で入れる。単一選択ならそのまま Enter で確定、複数選択では Enter 不要
- 最終確認は `❯ 1. Submit answers / 2. Cancel`。数字で選べる。
  **この画面にはヒント行（`Enter to select · …`）が出ない**ので、ヒント行だけを
  検出条件にすると確認画面で止まる（実機の通し確認で踏んだ）
- 質問が 1 つだけの単一選択にはタブ行も確認画面も無く、選んだ時点で確定する。
  ヒント行の文言も `Enter to select · ↑/↓ to navigate · Esc to cancel` に変わるので、
  `Tab/Arrow` を検出条件にしてはいけない

### 実装（`zellij-send-answer-question` / `C-c C-q` / メニュー `u`）

`zellij-send--askq-parse` が黒板バッファの内容（subscribe で 26〜40 ms 遅れの生画面）を
そのまま読んで質問・選択肢・チェック状態を取り出し、ミニバッファで選ばせて数字キーを送る。
`zellij` を追加で呼ばない（画面は既に手元にある）。

- **自動起動は `run-at-time 0` 経由**（`zellij-send--askq-maybe-auto` →
  `--askq-auto-open`）。`zellij-send--update-buffer` は subscribe のプロセスフィルタから
  呼ばれるので、そこで直接 `completing-read` を開くと C-g が効かない
- カーソル合わせ（`--askq-focus`、自由入力のときだけ必要）は 1 つずつ動かして
  毎回画面で確認する。移動量の一括計算は折り返しでずれる
- 歯止めは 2 段階: 同じ署名の画面が 3 回続いたら中止、加えて
  `zellij-send-askq-max-rounds`（既定 12）を超えたら無条件で中止。
  画面が毎回変わりながら空回りする不具合が実在したので、署名だけでは足りない

## スラッシュコマンド（調査済み・再調査不要）

2026-07-29 に Claude Code v2.1.220 + zellij 0.44.3（320 桁の背景セッション）で
実測した補完メニューの仕様。**同じ調査を繰り返さないこと。**

```
  /doctor       Health-check the user's Claude Code setup and fix issues: diagnose …
                MCP servers, and plugins versus their context cost and disable …   ← 折り返し
  /ndl          国立国会図書館(NDL)のデジタルコレクション…  (user)
─────────────────────────────────────────────────────────── ↯ ─   ← 入力枠の上罫線
❯ /
───────────────────────────────────────────────────────────
```

- 一覧はペインの補完メニューからしか取れない。**CLI には出す口が無い**
  （`claude --help` のサブコマンドにも無い。確認済み）
- **メニューは 4 行しか出ない**。説明が折り返すと 1 画面 2 件。実測 102 件を
  得るには ↓ を送りながら読み続けるしかない（`zellij-send--slash-collect`、約 8 秒）。
  取得結果は `zellij-send--slash-cache`（バッファローカル）に覚え、`C-u` で取り直す
- ↓ はカーソルを 1 件動かす。**カーソルが最下段に着いて初めて窓が 1 件ずつ動く**。
  送る回数は毎回「見えている件数 - 1」にする（1 件重なりが残る）。
  折り返しで 1 画面の件数が変わるので、**一定量を飛ばす実装にしてはいけない**
- 一覧は末尾から先頭へ折り返す。**折り返しをまたぐ回だけ窓が飛び、末尾が落ちる**
  （実測で `/verify` が 1 件だけ落ちた）。`zellij-send--slash-tail` が
  `/` を打ち直して **↑ を 1 回**送り、先頭で折り返した末尾の 1 画面を拾う
- **画面が前回と同じ間は ↓ を送らない**。描画待ちの画面を基準に送ると位置がずれる
- `/name ` まで打つと**引数のヒントがゴースト表示**される。
  `[low|medium|high|…]`（角括弧・選択肢）と `<path>`（山括弧・自由入力）の
  **両方の形がある**。`/agents` のように引数を取らないものは末尾の空白ごと消えて
  `/name` のまま。これが「引数が要るか」の唯一の判定材料
- `/config` は例外で、ヒントではなく設定キーの一覧がメニューに出る。ヒント無しと
  同じ扱い（引数なしで送る）にしてある。対話画面はキー透過モードで操作する
- 入力欄は **Ctrl+U（21）で消す。Esc では消えない**（実測。Esc の後に `/` を足すと
  `/c/` のようになりメニューが出なくなる）
- **`paste` で送ったテキストは補完メニューを開かない**。`/effort high` を paste して
  Enter でそのまま実行できるので、送信は既存の `zellij-send--send` でよい
- 一覧の取得も引数の判定も**ペインの入力欄を実際に打って**行う。だから
  `zellij-send--slash-idle-p` で入力欄が空（またはプレースホルダ `Try "…"`）で
  あることを必ず確かめる。ユーザーがターミナル側で書きかけたテキストを
  Ctrl+U で消さないため。選択肢プロンプトが出ている間は矢印がそちらに効くので、
  `zellij-send--askq-parse` が非 nil のときも触らない
- 画面は黒板バッファではなく毎回 `dump-screen` で取る。黒板はユーザーが編集中
  （`buffer-modified-p`）だと更新が止まるので当てにできない
- 入力欄は**一番下の `❯ ` 行**。会話ログにも `❯ /effort high` のような行が残るので、
  最初に見つけた `❯` を入力欄にしてはいけない

### 実装（`zellij-send-slash-command` / `C-c C-s` / メニュー `/`）

```
zellij-send-slash-command
  ├─ --slash-collect      入力欄が空か確かめ、`/` を打ってメニューを開く
  │    └─ --slash-scroll  ↓ を送りながら読む（見えている件数から回数を決める）
  │         └─ --slash-tail        `/` を打ち直し ↑ 1 回で末尾を拾う
  │              └─ --slash-collect-finish  Ctrl+U で片付け、名前順で返す
  ├─ --slash-choose       completing-read（初期入力 `/`、説明は注釈）
  ├─ --slash-probe-arg    `/name ` を打って引数ヒントを読み、Ctrl+U で片付ける
  └─ --slash-run          引数を尋ねて `zellij-send--send` で送る
```

- 純関数は `--slash-input-text` / `--slash-idle-p` / `--slash-menu-entries` /
  `--slash-arg-hint`。zellij を呼ばないのでテストがある（`test/` の
  `zellij-send-test-slash-*`）。画面を読む規則を変えるときはここを直す
- **ミニバッファは必ず `run-at-time 0` を挟んでから開く**（`--slash-choose` /
  `--slash-run` の呼び出し）。sentinel の中で `completing-read` を開くと
  C-g が効かない。AskUserQuestion と同じ約束
- 歯止めは `zellij-send-slash-max-rounds`（既定 200）と「3 回続けて進まなければ
  終了」の 2 段階。待ち時間は `zellij-send-slash-settle-delay`（既定 0.25 秒）

### 先読みとキャッシュ

- キャッシュは**作業ディレクトリごと**（`zellij-send--slash-cache-table`、
  キーは `file-truename` した `default-directory`）。一覧の中身を決めるのは
  プロジェクトのコマンドとスキルなので、同じディレクトリなら結果は同じ。
  2 つ目以降のセッションは取得ゼロで開ける（実測で確認）
- `zellij-send--subscribe-start`（＝ペインに繋がった時点）から
  `zellij-send--slash-prefetch-maybe` を呼び、`zellij-send-slash-prefetch-delay`
  （既定 5 秒）後に黙って取りに行く。取れなければ
  `zellij-send-slash-prefetch-retries`（既定 4）回まで置き直して再試行する
  ——起動直後は信頼確認などで入力欄が空でないことがあるため
- 先読み中は `zellij-send--slash-prefetching`（バッファローカル）が真になり、
  `zellij-send--slash-msg` が進捗・失敗メッセージを黙らせる。**動的束縛は使えない**
  （コールバックが sentinel / タイマーをまたぐので `let` が生き残らない）
- **取得中に入力欄が `/` 以外になったら即中止する**（`--slash-scroll` の先頭の分岐）。
  ユーザーがターミナル側で打ち始めた合図なので、Ctrl+U で片付けずに手を引く。
  このとき**部分的な一覧は返さない**（nil を返す）。中途半端な一覧を
  キャッシュに焼き付けると、以後ずっと欠けたまま出てしまう。
  実測: 中止後の入力欄は `/ユーザーの入力` になる（先頭の `/` は残るが、
  相手の入力は消えない）

### 決めたこと（2026-07-29）

- **一覧は画面から拾う**。静的リストを持たない。Claude Code の更新・スキルの
  増減とずれないことを優先し、代わりに取得コスト（約 8 秒）はキャッシュで吸収する
- **引数は選択後に一度だけ聞く**。ヒントが `a|b|c` なら補完候補、それ以外は
  自由入力、ヒント無しなら聞かずに送る
- **対話画面が出るコマンドは送るところまで**。自動でキー透過モードに入ったりしない
  （`/clear` のように対話画面が出ないコマンドでも read-only になってしまうため）
- **一覧は先読みする**（黒板バッファがペインに繋がった数秒後に一度）。
  初回の 8 秒を体感させないため。ペインにキーを送るのが嫌なら
  `zellij-send-slash-prefetch` を nil にする
- **`/compact`（`c`）と `/clear`（`C`）のメニュー項目は外した**。`/` で全部送れる
  ようになったので二重に置かない。`zellij-send-compact` /
  `zellij-send-cc-clear` は M-x 用に残す（前者はダッシュボードの `c` が呼ぶ。
  依存は dashboard → 本体の一方向なので消してはいけない）

## キー透過モード（`zellij-send-keys-mode` / `C-c C-t`）

黒板バッファは既にペインの生画面を映しているので、足りないのは打つ側だけ、という発想。
有効な間、↑↓←→ / RET / TAB / ESC / DEL / 印字文字を
`zellij-send--send-keys` でペインへ流す（印字文字は `self-insert-command` の remap で拾い、
UTF-8 バイト列に分解して送る）。画面を解釈しないので、AskUserQuestion に限らず
権限ダイアログや `/model` の選択にも効く。

有効中はバッファを read-only にする。誤って編集すると `buffer-modified-p` が真になり、
自動更新が止まって画面が固まったように見えるため。

## ダッシュボード（zellij-send-dashboard.el）

`M-x zellij-send-dashboard` / メニュー `d`。全セッションを tabulated-list で一覧する。
**依存は一方向**: dashboard → 本体。本体から `zellij-send-dashboard` を require せず、
メニューの `d`（`zellij-send-open-dashboard`）が `fboundp` / `require ... noerror` で
遅延ロードする。本体からダッシュボードのシンボルを参照しないこと。

状態判定・キー・Remote Control の QR・使用状況（`/usage` 相当）の実測仕様は
`.claude/skills/zellij-send-dashboard/SKILL.md` に分けてある（触るときに読み込まれる）。

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
- **`viewport` の各行はペイン幅ぶんスペースで右パディングされている**
  （`dump-screen` はされない。2026-07-29 実測）。320 桁の背景セッションでは
  1 行あたり数百文字の空白が付き、実データで **24407 文字 → 2175 文字（91% が空白）**
  だった。`zellij-send--process-dump` が行末空白と末尾の連続空行を落とすので、
  **この処理を外さないこと**。ANSI 除去より後に削る（エスケープが残っていると
  行末を判定できない）
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

## 会話履歴の表示（`zellij-send-show-response` / メニュー `a`）

`a` は Claude Code のときだけ **transcript の JSONL を読んで会話を最初から黒板に流す**。
Claude Code 以外（`zellij-send-default-command` が claude で始まらない）と `C-u a` は
従来どおり `dump-screen --full`。

- transcript の場所は `~/.claude/projects/SLUG/*.jsonl`。SLUG は cwd の
  **英数字以外をすべて `-` に置換**したもの（`/Users/mck/.claude` →
  `-Users-mck--claude`。2026-08-02 に実在ディレクトリ名で確認）
- 同じ cwd に複数の jsonl があるので**最終更新が最新のものを選ぶ**。
  Stop フックは transcript のパスを Emacs に渡していないため、これ以上は絞れない。
  同一ディレクトリで 2 セッション動かすと取り違えうる（既知の制約）
- 出すのは `user` / `assistant` 行のみ。ブロックは
  **text / thinking / tool_use / tool_result を全部出す**。
  `mode` / `ai-title` / `file-history-snapshot` などの行は会話ではないので捨てる
- **`tool_result` は role が `user`** だが、ユーザーの発言ではないので見出しは `tool` にする
- **画像ブロックは base64 を出さず要約に置き換える**（`--transcript-block`）。
  実測で 89692 文字の 1 行になっていた。`[画像 image/png 66 KB]` の形にする
- **長い 1 行は切る**（`--transcript-clip`、既定 2000 文字）。行数制限
  （`--max-block-lines`）では止まらない。`tool_use` の入力は `json-encode` した
  改行なしの 1 行なので、`Write` 1 回で 6918 文字になった（実測）。
  **切るのは行数を数える前**（順序を入れ替えると長い 1 行が生き残る）
- **`zellij-send--update-buffer` を使ってはいけない**。あれはプロンプト検出と
  AskUserQuestion の自動起動を伴うので、過去の会話文で誤爆する。直接 insert する
- 表示後は `zellij-send--user-cleared` を立てる。これをしないと
  **26〜40 ms 後の subscribe イベントに上書きされて消える**
- 生画面に戻す経路は `zellij-send-show-live`（メニュー `g`）。`--user-cleared` と
  `buffer-modified-p` の**両方**を落としてから `dump-screen` で取り直す。
  **解除はコールバックの中ではなく取得を投げる前に行う**——`--user-cleared` が
  立ったままだと `--update-buffer` が書き込みを拒み、コールバックが空振りする。
  編集済みのバッファでは下書きを捨てる確認を挟む（クリア `x` や送信でも
  `--user-cleared` は nil に戻るが、取り直しはしない）
- 純関数は `--transcript-slug` / `--transcript-entries` / `--transcript-format` /
  `--transcript-trim` / `--transcript-clip` / `--transcript-block` /
  `--transcript-claude-p`。テストが `test/` にある

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

`--full` 自体は正常。**流れて消えた会話は画面からは絶対に取れない**ので、
transcript（Claude Code が書く JSONL）から読む。経路は 2 つ:
`C-c C-a` → `a`（`zellij-send-show-response`、下記）と `l`（`zellij-send-log-file`、
Stop フックが追記）。
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

セッション名は**ディレクトリ名 + 2 桁の連番**（`myproj00`）。1 体目から番号を付ける。
同じプロジェクトで複数エージェントを立てるためで、**エージェント 1 体 = zellij セッション 1 つ**。
バッファ名がセッション名と 1 対 1 のまま（`*ai-myproj01*`）なので、履歴・subscribe・
`zellij-send-quit`・ダッシュボードはどれも既存の仕組みのまま効く。

- `zellij-send--numbered-session-name` が空いている最小の番号を選ぶ。候補の除外集合は
  `zellij-send--taken-session-names`（`list-sessions` の結果 **＋ 開いている黒板バッファの
  `zellij-send--session`**）。作成直後でまだ一覧に出ないセッションと衝突させないため
- `zellij-send--session-base` は**末尾 2 桁だけ**を剥がす。数字を貪欲に剥がすと
  `project200`（= `project2` の 1 体目）の基底名が `project` になる
- 追加は `zellij-send-add-agent`（メニュー `+`）。いまのバッファの `default-directory` と
  基底名を引き継ぐのでディレクトリを聞かない。`list-sessions` のコールバックは sentinel の
  中なので、**`run-at-time 0` を挟んでから** `--spawn-session`（`switch-to-buffer` を含む）を呼ぶ
- 実体の作成は `zellij-send--spawn-session`（セッション名と dir を受け取る）。
  `zellij-send--create-new-session` はディレクトリを尋ねて名前を決めるだけの薄い層

`zellij-send--spawn-session` のフロー（すべて非同期）:
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
