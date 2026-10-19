# CLAUDE.md

## このファイルの規約（先に読むこと）

- **追記型ではない。更新型である。** 書き足す前に、既存の項目を直すか統合できないか考える。
  古くなった記述は消す。同じことを 2 か所に書かない。
- 入れてよいもの: 動かせない制約、恒久的な設計判断とその理由、禁止事項。
- 入れてはいけないもの: セッションごとの作業ログ、やったことの時系列、TODO の消化記録、
  **同じ内容をコードコメントが既に持っているもの**（ここにはコメントの場所だけ書く）。
- **上限 200 行。** 超えたら古い項目を統合するか、該当コードのコメントへ移す。
- 実測の詳細（表・数値・再現手順）はコードコメント（`;;` の調査メモ）に一本化する。
  ここに置くのは「何が動かせないか」の一行と、詳しく書いてある場所だけ。
- 2026-10 以前の長い版（実測の表を含む）は git 履歴の `be6c0c8:CLAUDE.md` にある。

## プロジェクトの前提（壊してはいけない）

Emacs から detached な zellij セッションで動く AI エージェント（claude / codex / agy）を
操作する Emacs パッケージ。成り立ちの中心は 2 点で、どちらも改善の名目で壊さない。

1. **エージェントは Emacs より長生きする。** `zellij attach --create-background` で作り、
   pane-id 指定で送受信する。Emacs の再起動・フレームを閉じる・ターミナルからの
   `zellij attach` のどれでも同じセッションが続く。
   → ACP / agent-shell（stdio でエージェントを子プロセスにする）方式には移らない。
2. **文章を作るのは普通の Emacs バッファ。** vterm / eat を使わないので、Emacs 内で動く
   入力メソッド（ddSKK など）が生きる。eat は attach 起因のフリーズが解消できず全廃した。
   → vterm / eat を再導入しない。

## 開発環境・検証

- Emacs 28.1+（`lexical-binding: t`）。依存は `transient`（必須）と `markdown-mode`（任意）だけ。
  外部コマンドは `zellij` 0.44+ / `sh` / `python3` のみ。**新しい依存を足さない**
- 検証は `make`（バイトコンパイル → テスト → checkdoc）。`make test` / `make compile` で個別に。
  バイトコンパイルは警告もエラーにする（警告を増やさない）。checkdoc は日本語 docstring の
  誤検知が多いので件数を見るだけ。Emacs は `make EMACS=…` で差し替える
- テストは zellij を呼ばない純関数と、バッファ更新の振る舞い（`test/zellij-send-test.el`）、
  実機の画面（`test/fixtures/`）をパーサに通すもの（`test/zellij-send-parse-test.el`）。
  性能の見張りは `make bench`（機械依存なので `make` には入れない）
- zellij を叩く経路は、`ZELLIJ_SOCKET_DIR` を分けた使い捨てサーバで手で確かめる
  （普段のダッシュボードが自動接続しないように。パスは 104 バイト未満）
- GUI の描画を確かめるときは別の `emacs -Q` を使い、既定フォントは
  `:font "Mplus 1 code-14"` で指定する（`:family` + `:height` は `-Q` で効かない）

## 禁止事項

- **zellij 呼び出しに同期呼び出し（`call-process` など）を入れない。** 全部 `make-process` +
  sentinel。引数は文字列のリストで渡し、シェル文字列を組まない。ユーザーテキストの前に `--`
- **sentinel / プロセスフィルタの中でミニバッファを開かない。** `run-at-time 0` で抜けてから聞く
  （その中では quit が抑止され C-g が効かない）。操作（op）の途中なら `--op-later` で抜ける
- **ペインの入力欄に打ちながら進む非同期の操作は `zellij-send-op` を通す。** 始めるのは
  `--op-begin`（黒板ごとに 1 つだけ・排他）、待つのは `--op-later`（素の `run-at-time` は
  `zellij-send-abort` で止められない）、入出力は `--op-dump` / `--op-keys` / `--op-write-chars`
  （止めた後に遅れて返った処理がキーを送らない）。結果は `(:ok V)` / `(:failed R)` /
  `(:aborted R)` で返し、型で成否を見分けない
- **ペインに打ち込む機能は `zellij-send--assert-capability`（確定が要る）で守る。** 推測の
  `zellij-send--capable-p`（不明なら既定コマンドで代用する）は読むだけの機能にしか使わない
- **CLI ごとの知識は `zellij-send-agents` の 1 か所だけに置く。** 名前の文字列
  （`"claude"` など）で分岐を書かず、能力（`:capabilities`）で問い合わせる。
  **未確認の能力を足さない**。エージェントの自己申告は信用しない
  （agy は `/compact` が「ある」と答え、実機が否定した）
- **日付入りの実測コメントを消さない・書き換えない。** 変えるときは新しい実測を日付付きで追記する
- **画面の形に新しい仮定を置かない。** 置くなら実機で確かめ、日付と版をコメントに残し、
  画面は `test/fixtures/capture.sh` で fixture にしてテストに足す
- 本体（`zellij-send*.el`）からダッシュボードを require しない・シンボルを参照しない。
  依存は dashboard → 本体の一方向（メニュー `d` は `require ... noerror` で遅延ロード）。
  ダッシュボードは本体の公開 API（「セッションの状態と操作（公開 API）」節）だけを使い、
  2 ハイフンの名前を参照しない
- 打ち切った（`truncated`）スラッシュコマンド・引数の一覧をキャッシュしない
- 1 タスク 1 コミット。指示されていないリファクタ・整形・リネームを混ぜない

## 動かせない制約（詳細はコメントの場所へ）

### 背景セッションの大きさ
`attach --create-background` のセッションは 50 桁 × 48 行に固定。**`COLUMNS` / `LINES` は
新規サーバでも効かない**（2026-07-28、zellij 0.44.3）。唯一効くのは目的の大きさの pty で
一瞬 attach → detach すること（`zellij-send--resize-session`。ペインを作る前に行う）。
この attach は全面非同期・出力を捨てる `:filter` 必須・watchdog で必ず殺す
（Emacs が pty を読まないと zellij サーバが書き込みでブロックし、セッション全体が固まる）。

### subscribe
`zellij subscribe` は `--pane-id` 必須、viewport は毎回フル、行末はペイン幅ぶん空白で
パディングされる。**存在しないセッションでも終了コード 0 で何も流さない**、
**セッションが消えても終了しない**——成否は初回イベントの有無で見て、後始末は
`kill-buffer-hook` で行う。詳細は `zellij-send-core.el` の「自動受信（zellij subscribe）」節。

### 行末の空白の削り方
受信した行を `string-trim` / `[ \t]+$` で削らない（2 乗時間で Emacs が止まる）。
`zellij-send--trim-end` を使う（docstring に計測あり）。

### 終了コードが当てにならないもの
- `list-sessions` は 0 件でも exit 1（案内文で見分ける。`zellij-send--list-sessions-async`）
- `subscribe` は失敗しても exit 0（上記）
- タイムアウト・失敗を「セッション 0 件」と読まない（生きている黒板を kill してしまう）

### セッションの終了
エージェントが `/exit` で落ちてもペインは `EXITED=true` で残り、セッションは消えない。
終了は `list-panes --all` の EXITED 列で見て `delete-session --force` で消す
（`zellij-send--await-agent-exit`）。判定できないときに t を返さない。

### 画面から取れないもの
alt-screen の TUI にはスクロールバックが無く（`dump-screen --full` も効かない）、
長文の送信は `[Pasted text #1 +N lines]` に畳まれる。過去の会話は transcript（JSONL）から読む。

## 設計判断（理由つき）

- **ファイルは 5 つに分け、依存は上から下の一方向**（`zellij-send.el` → `-ui` → `-claude` →
  `-core` → `-parse`）。逆向きの require・自分自身への `declare-function`・値の無い
  `defvar` を置かない。下の層が上の層を呼ぶ必要があるときは差し込み口を作る
  （受信した画面の描画は `zellij-send--display-function`、ペインに繋がった時の処理は
  `zellij-send--pane-connected-hook`）。`-parse` は文字列を受けて構造を返す関数だけ。
  公開 API は `-ui` にあるので、ダッシュボードは `zellij-send` を require する

- **エージェント 1 体 = zellij セッション 1 つ。** 名前はディレクトリ名 + 2 桁連番
  （`myproj00`）。バッファ・履歴・subscribe・終了がセッション単位のまま効く
- **機能の分岐はバッファローカルの `zellij-send--command` で行う。**
  `zellij-send-default-command` は新規作成時の既定値でしかない。pane-id を替えるときは
  コマンドを nil でも代入し、subscribe を張る前に確定させる（先読みが `/` を打つため）
- **ペインは TITLE ではなく `list-panes --all` の COMMAND 列で選ぶ**（TITLE は当てにならない）
- **本文は `write-chars` ではなく `paste` で送る。** `write-chars` は LF を素通しし、
  シェルでは行ごとに実行される。Enter は別に `write 13`
- **送信後の後処理（クリア・返信バッファを閉じる）は成功コールバックの中で、送信開始時の
  `buffer-chars-modified-tick` と比べてから行う。** 失敗・途中編集で下書きを失わない
- **黒板は編集中（`buffer-modified-p`）・クリア後（`zellij-send--user-cleared`）は書き換えない。**
  ただし `zellij-send--last-change-time` / `--last-content` は記録し続ける
- **画面を解析する処理は黒板の中身（`buffer-string`）を読まない。** 黒板は下書き・
  クリア・transcript 表示で画面と食い違ううえ、表示形（罫線を削り空行を詰めた形）で
  ある。パーサが読むのは正規形（`--normalize-screen`）だけで、表示形を作るのは
  `--update-buffer` の中の `--screen-for-display` だけ。打ち込む処理（AskUserQuestion・
  スラッシュコマンド）はそのつど `dump-screen` で取り直し、読むだけの処理
  （ダッシュボード）は `zellij-send--last-screen` を読む
- **transcript は明示選択か、状態フックが知らせたもの。** 更新日時から所属を推測して
  自動で選ばない（同じディレクトリに複数エージェントがいるため）。ユーザーの選択が優先
- **作業中・選択待ち・待機は本体が導く**（`zellij-send-session-state`）。ダッシュボードが
  決めるのは表示側の概念の「完了」だけ。選択待ちの判定は `--screen-prompt-p` の 1 本
- **ダッシュボードは zellij を呼ばない。** セッションの検出（自動接続・消えた黒板の片付けと
  履歴の破棄）は本体の監視（`zellij-send-start-session-watch`）が行い、ダッシュボードを
  開かなくても動く。実測仕様は `.claude/skills/zellij-send-dashboard/SKILL.md`
- **モードライン通知は持たない**（再描画のたびに全バッファを走査するため 2026-07 に撤去）

## 実測の置き場所（再調査しないこと）

| 話題 | 場所 |
|---|---|
| AskUserQuestion の画面と操作 | `zellij-send-claude.el`「AskUserQuestion（選択肢プロンプト）への回答」節の冒頭 |
| スラッシュコマンドの補完メニュー・引数 | `zellij-send-claude.el`「スラッシュコマンド」節の冒頭と「引数を読む」 |
| 黒板の桁揃え・記号の字形 | `zellij-send-grid-align` ほか `--grid-*` の docstring |
| 末尾を追う・選択中の保留 | `zellij-send--update-buffer` の前のコメント |
| CLI ごとの差（記号・数字キー・`/compact`・指示ファイル） | `zellij-send-agents` の定義の前のコメント |
| transcript の場所・題名 | `zellij-send--transcript-*` の docstring |
| ダッシュボード・/usage | `.claude/skills/zellij-send-dashboard/SKILL.md` |
| 実機の画面そのもの（版・幅つき） | `test/fixtures/`（採り方は `capture.sh` の先頭） |

### コードに無い CLI の実測（2026-09-07、zellij 0.45.1）

- codex: Ctrl+U は入力欄を **1 行ずつ**しか消さない（claude / agy は 1 回で空）。
  codex の入力欄を片付ける処理を書くならここに注意
- codex: 長文は `[Pasted Content N chars]` に畳まれる（2399 字・1565 字は畳まれ、1000 字は畳まれない）
- agy: 信頼確認の画面だけ番号が無い（`> Yes, I trust this folder`）。キー透過モードで操作する
- agy: Esc 1 回で中断できる。補完メニューは 5 件 + `↓ N more` の形

## コーディング規約

- 公開は `zellij-send-FOO`、内部は `zellij-send--FOO`。バッファローカル状態は `defvar-local`
- docstring・メッセージは日本語。`user-error` は操作ミス、`error` はプログラムの誤り
- 新しい関数は既存の `;;;` 見出しの下に置く（末尾に足さない）
- 純関数を足したら `test/zellij-send-test.el` にテストを足す。入力は実画面を模した固定文字列
