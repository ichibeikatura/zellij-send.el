---
name: zellij-send-dashboard
description: >-
  zellij-send-dashboard.el（M-x zellij-send-dashboard / メニュー d）を読み書き
  するときの実測済み仕様。セッション一覧の状態判定（作業中・完了・選択待ち）、
  tabulated-list の更新とキー（g / ? / r / G）、Remote Control の QR 取り込み、
  /usage 相当の使用状況表示。トリガー例:
  「ダッシュボード」「zellij-send-dashboard.el」「QR」「/usage」「使用状況バー」。
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

**`rate_limits` は毎回来るとは限らない**（2026-08-02 実測）。API 応答から来る
情報なので、まだ 1 往復もしていないセッションの statusLine 呼び出しには入って
いない。キャッシュは全セッション共通の 1 ファイルで最後に書いた者が勝つため、
そのまま上書きすると「レート制限の情報がありません（Claude サブスク以外、
または API 応答前）」に化ける。**引き継ぎはフック側でやる**
（`statusline-zellij-send.sh` が、無いときだけ前回の `rate_limits` を移し、
併せて mtime も前回のものに戻す）。Emacs 側に前回値を持たせると、
mtime ベースの「◯前の記録」と食い違うので入れないこと。

am/pm と月名は `format-time-string` の `%p` / `%b` がロケール依存（日本語環境では
「午後」「 7」になる）ため自前で組み立てる。

