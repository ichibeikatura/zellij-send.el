---
name: zellij-send-dashboard
description: >-
  zellij-send-dashboard.el（M-x zellij-send-dashboard / メニュー d）を読み書き
  するときの実測済み仕様。セッション一覧の状態判定（作業中・完了・選択待ち）、
  tabulated-list の更新とキー（g / ? / G）、/usage 相当の使用状況表示。トリガー例:
  「ダッシュボード」「zellij-send-dashboard.el」「/usage」「使用状況バー」。
---

# zellij-send ダッシュボードの実装ノート

`zellij-send-dashboard.el` を触るときだけ必要な、実機で確かめた仕様。
本体側の作法（全面非同期・pane-id・subscribe）はリポジトリの `CLAUDE.md` を見ること。

## 概要

`M-x zellij-send-dashboard` / メニュー `d`。全セッションを tabulated-list で一覧し、
要対応順（選択待ち → 完了 → 作業中 → 待機）に並べる。

- **依存は一方向**: dashboard → 本体。本体は `zellij-send-dashboard` を require せず、
  メニューの `d`（`zellij-send-open-dashboard`）が `fboundp` / `require ... noerror` で
  遅延ロードする。本体からダッシュボードのシンボルを参照しないこと
- **本体の内部には触らない**: ダッシュボードが使うのは本体の公開 API
  （`zellij-send-sessions` / `zellij-send-session-state` / `zellij-send-session-screen` /
  `zellij-send-choice-to-session` など。`zellij-send-ui.el` の「セッションの状態と操作（公開 API）」節）
  だけ。2 ハイフンの名前を参照しない
- **作業中・選択待ち・待機は本体が導く**（`zellij-send-session-state` の `:status`）。
  各セッションが最後に受け取った画面（`zellij-send-session-screen`）から毎回算出する。
  黒板の中身（`buffer-string`）は下書き・クリア・transcript 表示で画面と食い違うので読まない
  - 作業中: スピナー行（`zellij-send-working-regexp`。`esc to interrupt` と、
    v2.1.303 の `✳ Concocting… (7s · …)` の形）がある **か**、画面が
    `zellij-send-active-window` 秒以内に変化した。
    **Claude Code は本文を流している間スピナー行を出さない**（実機で確認）ため、
    スピナーだけで判定すると回答中を「待機」と誤表示する。画面が動いていること
    自体を処理中の証拠として使う
  - 選択待ち: `zellij-send--screen-prompt-p`（AskUserQuestion として読める画面なら
    それを正とし、読めなければ記号の正規表現に落ちる）
  - **フック（README の state-zellij-send.sh）が知らせた状態があれば画面より優先**
    （`zellij-send--hook-status`）。
    Esc の中断では Stop フックが来ないので、作業中は画面が
    `zellij-send-hook-stale` 秒止まったら、選択待ちはダイアログを描いた後に
    画面が変わったら捨てて画面解析に戻す。フック未設定なら画面解析だけ
  - 旧名の `zellij-send-dashboard-working-regexp` / `-active-window` / `-use-hooks` /
    `-hook-stale` は本体の新しい名前への obsolete alias
- **完了だけはダッシュボードが決める**: 作業中だったセッションが作業中でなくなった瞬間に
  立て、そのバッファがウィンドウに表示された時点で解除（`zellij-send-dashboard--update-state`）。
  ウィンドウの可視性で決まる表示側の概念なので、本体の状態には入れない
- **zellij を追加で呼ばない**: 表示は本体が subscribe で受けた結果（受け取った画面と
  最終変化時刻。`zellij-send-session-state` の `:changed-at`）を読むだけ
  （セッションの検出——未接続のセッションへの接続と消えた黒板の片付け——は
  本体の監視 `zellij-send-start-session-watch` が行い、黒板が増減したら
  `zellij-send-sessions-changed-hook` で再描画する。2026-10-20 まではダッシュボードが
  15 秒ごとに検出していたので、開かないと死んだ黒板と履歴が残った）

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
### Remote Control（QR の取り込みは撤去済み）

ダッシュボードの `r`（`/remote-control` のメニューをカーソルで辿り、QR を SVG に起こす）は
撤去した。起動時の `--remote-control SESSION`（本体の `zellij-send-remote-control`）が
画面を読まない経路として残り、起動済みのセッションはキー透過モードでメニューを操作する。
メニューの実測（項目の説明が折り返すので移動量を行数で数えると `Disconnect this session`
を選ぶ、接続に 10 秒以上かかる、など）と旧実装は git 履歴の
`ede1d97:zellij-send-dashboard.el` にある。

### 使用状況バーの描き方

**フォント依存の描画は避ける**: 使用状況バーはブロック文字をやめ（M PLUS 等では字形が
行高を超えて崩れる）、空白に `:background` を付けて描くのが既定（`zellij-send-dashboard-usage-bar-style`
の `face`）。グリフに頼らないのでフォントの字形に影響されない。

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

**`rate_limits` は毎回来るとは限らない**（2026-08-02 実測）。API 応答から来る
情報なので、まだ 1 往復もしていないセッションの statusLine 呼び出しには入って
いない。キャッシュは全セッション共通の 1 ファイルで最後に書いた者が勝つため、
そのまま上書きすると「レート制限の情報がありません（Claude サブスク以外、
または API 応答前）」に化ける。**引き継ぎはフック側でやる**
（`statusline-zellij-send.sh` が、無いときだけ前回の `rate_limits` を移し、
併せて mtime も前回のものに戻す）。Emacs 側に前回値を持たせると、
mtime ベースの「◯前の記録」と食い違うので入れないこと。

例外は **JSON を解釈できなかったとき**（フックの書きかけ・壊れたファイル。2026-10-20）。
`--read-usage` は `:failed` を立て、前に読めた値があればそれを**その値の mtime ごと**
返す（経過時間は前の値のもの。「（最新の読み取りに失敗）」を添える）。無ければ
「読み取りに失敗」と出し、ファイルが無いときの「README の statusLine フック設定を参照」
とは分ける（フックは動いているのに設定を疑わせないため）。

am/pm と月名は `format-time-string` の `%p` / `%b` がロケール依存（日本語環境では
「午後」「 7」になる）ため自前で組み立てる。

**2 本のバーは色で見分ける**。使用率が近いと（実測 14% と 13%）同じ face・同じ長さに
なり区別できない。`Current session`（`five_hour`）だけ
`zellij-send-dashboard-usage-light-ratio`（既定 0.4）ぶん背景色へ寄せて薄くし、
`Current week` は従来の濃さのままにする（`zellij-send-dashboard--usage-color` の
LIGHT 引数）。**色相は変えない**——緑・黄・赤の 3 段階は使用率の警告なので、
種別で色相を変えると意味が二重になる。

**薄めるのは `display-graphic-p` のフレームだけ**（2026-08-02 実測）。tty では
`color-values` が端末のパレットに丸めるため、橙 `#c07000` も赤 `#b00000` も
純赤 `(65535 0 0)` になり、混ぜると色相ごと壊れる。tty では薄めずに従来の色で出す。

