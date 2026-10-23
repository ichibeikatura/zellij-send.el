#!/bin/sh
# テスト用の fixture（実機の画面の記録）を採る。リファクタリング指示書フェーズ 2・3 用。
#
# 画面の中身は zellij が返したバイト列をそのまま保存する。先頭に `#fixture: ' で
# 始まる注記行（採取日時・zellij と CLI の版・ペインの行）を付ける。注記はテスト側が
# 読み込み時に落とす（パーサには注記の知識を持たせない）。
#
# 使い方（S = セッション名、P = pane-id。例: zjsfx00 terminal_1）:
#   capture.sh panes S                   ペイン一覧を表示する（P を調べる）
#   capture.sh dump  S P NAME [メモ]      画面を NAME.txt に保存
#   capture.sh dump-ansi S P NAME [メモ]  色付きのまま（--ansi）NAME.ansi に保存
#   capture.sh burst S P NAME [回数]      0.5 秒ごとに NAME-01.txt … を保存（既定 10 回）
#   capture.sh type  S P 文字列           入力欄に打つ（write-chars。補完メニューが開く）
#   capture.sh send  S P 文字列           本文として送って Enter（paste + CR。黒板の送信と同じ）
#   capture.sh key   S P キー [回数]      up down left right enter esc tab space ctrl-u 1〜9
#   capture.sh list-panes S NAME          `list-panes --all' の出力を NAME.txt に保存
#   capture.sh sessions                   list-sessions.txt と list-sessions-empty.txt を保存
#   capture.sh list-clients S NAME        `list-clients' の出力を NAME.txt に保存
#   capture.sh list-sessions NAME         `list-sessions' の出力を NAME.txt に保存
#   capture.sh subscribe S P NAME         subscribe の最初の 1 イベントを NAME.jsonl に保存
#
# claude 以外の CLI の版は自動では取らない。AGENT=codex AGENT_VERSION=… のように渡す。

set -u
ZELLIJ_BIN=${ZELLIJ_BIN:-zellij}
DIR=$(cd "$(dirname "$0")" && pwd)

die() { echo "capture.sh: $*" >&2; exit 1; }

agent_version() {
  agent=${AGENT:-claude}
  if [ -n "${AGENT_VERSION:-}" ]; then
    echo "$agent $AGENT_VERSION"
  elif [ "$agent" = claude ]; then
    echo "claude $(claude --version 2>/dev/null || echo unknown)"
  else
    echo "$agent unknown（AGENT_VERSION で指定）"
  fi
}

# header NAME SESSION PANE NOTE
header() {
  echo "#fixture: name=$1"
  echo "#fixture: captured=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "#fixture: zellij=$($ZELLIJ_BIN --version 2>/dev/null)"
  echo "#fixture: agent=$(agent_version)"
  if [ -n "$2" ]; then
    panes=$($ZELLIJ_BIN --session "$2" action list-panes --all 2>/dev/null)
    echo "#fixture: panes-header=$(printf '%s\n' "$panes" | head -n 1)"
    [ -n "$3" ] && echo "#fixture: pane=$(printf '%s\n' "$panes" | grep -E "[[:space:]]$3[[:space:]]")"
  fi
  [ -n "$4" ] && echo "#fixture: note=$4"
  return 0
}

# dump_to FILE NAME S P NOTE [dump-screen に足す引数]
dump_to() {
  tmp=$(mktemp "${TMPDIR:-/tmp}/zjsfx.XXXXXX") || die "mktemp に失敗"
  if ! $ZELLIJ_BIN --session "$3" action dump-screen --pane-id "$4" ${6:-} > "$tmp"; then
    rm -f "$tmp"; die "dump-screen に失敗（$3 $4）"
  fi
  { header "$2" "$3" "$4" "$5"; cat "$tmp"; } > "$1"
  rm -f "$tmp"
  echo "保存: $1"
}

key_bytes() {
  case "$1" in
    up) echo "27 91 65" ;; down) echo "27 91 66" ;;
    right) echo "27 91 67" ;; left) echo "27 91 68" ;;
    enter) echo 13 ;; esc) echo 27 ;; tab) echo 9 ;; space) echo 32 ;;
    ctrl-u) echo 21 ;;
    [1-9]) echo $((48 + $1)) ;;
    *) die "知らないキー: $1" ;;
  esac
}

cmd=${1:-}; [ -n "$cmd" ] || die "使い方は先頭のコメントを参照"; shift

case "$cmd" in
  panes)
    [ $# -ge 1 ] || die "panes S"
    $ZELLIJ_BIN --session "$1" action list-panes --all ;;
  dump)
    [ $# -ge 3 ] || die "dump S P NAME [メモ]"
    dump_to "$DIR/$3.txt" "$3" "$1" "$2" "${4:-}" ;;
  dump-ansi)
    [ $# -ge 3 ] || die "dump-ansi S P NAME [メモ]"
    dump_to "$DIR/$3.ansi" "$3" "$1" "$2" "${4:-}" --ansi ;;
  burst)
    [ $# -ge 3 ] || die "burst S P NAME [回数]"
    n=${4:-10}; i=1
    while [ "$i" -le "$n" ]; do
      dump_to "$DIR/$3-$(printf %02d "$i").txt" "$3" "$1" "$2" "burst $i/$n"
      i=$((i + 1)); sleep 0.5
    done ;;
  type)
    [ $# -ge 3 ] || die "type S P 文字列"
    $ZELLIJ_BIN --session "$1" action write-chars --pane-id "$2" -- "$3" ;;
  send)
    [ $# -ge 3 ] || die "send S P 文字列"
    $ZELLIJ_BIN --session "$1" action paste --pane-id "$2" -- "$3" || die "paste に失敗"
    $ZELLIJ_BIN --session "$1" action write --pane-id "$2" -- 13 || die "write に失敗" ;;
  key)
    [ $# -ge 3 ] || die "key S P キー [回数]"
    bytes=$(key_bytes "$3") || exit 1
    n=${4:-1}; i=1
    while [ "$i" -le "$n" ]; do
      # shellcheck disable=SC2086
      $ZELLIJ_BIN --session "$1" action write --pane-id "$2" -- $bytes || die "write に失敗"
      i=$((i + 1)); sleep 0.15
    done ;;
  list-panes)
    [ $# -ge 2 ] || die "list-panes S NAME"
    f="$DIR/$2.txt"
    { header "$2" "" "" "zellij --session $1 action list-panes --all"
      $ZELLIJ_BIN --session "$1" action list-panes --all; } > "$f"
    echo "保存: $f" ;;
  list-clients)
    [ $# -ge 2 ] || die "list-clients S NAME"
    f="$DIR/$2.txt"
    { header "$2" "" "" "zellij --session $1 action list-clients"
      $ZELLIJ_BIN --session "$1" action list-clients; } > "$f"
    echo "保存: $f" ;;
  list-sessions)
    [ $# -ge 1 ] || die "list-sessions NAME"
    f="$DIR/$1.txt"
    # 0 件でも exit 1 で、案内文は stderr に出る。本体と同じく両方を 1 つに受ける
    { header "$1" "" "" "zellij list-sessions（stdout と stderr）"
      $ZELLIJ_BIN list-sessions 2>&1; } > "$f"
    echo "保存: $f" ;;
  sessions)
    "$0" list-sessions list-sessions
    # 0 件の画面は、使い捨てのソケット置き場で取る（普段のサーバに触らない）
    sock=$(mktemp -d /tmp/zjsfx-sock.XXXXXX) || die "mktemp に失敗"
    f="$DIR/list-sessions-empty.txt"
    { header list-sessions-empty "" "" "空の ZELLIJ_SOCKET_DIR で zellij list-sessions（stdout と stderr）"
      ZELLIJ_SOCKET_DIR=$sock $ZELLIJ_BIN list-sessions 2>&1; } > "$f"
    rmdir "$sock" 2>/dev/null
    echo "保存: $f" ;;
  subscribe)
    [ $# -ge 3 ] || die "subscribe S P NAME"
    # `| head -n 1' で受けると、画面が変わらない限り subscribe が書き込まず、
    # パイプが閉じたことに気付かないまま終わらない。1 行届いたら自分で殺す
    f="$DIR/$3.jsonl"; tmp="$f.part"
    $ZELLIJ_BIN --session "$1" subscribe --pane-id "$2" --format json > "$tmp" &
    pid=$!; i=0
    while [ "$i" -lt 150 ] && [ "$(wc -l < "$tmp" | tr -d ' ')" -lt 1 ]; do
      sleep 0.1; i=$((i + 1))
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    [ "$(wc -l < "$tmp" | tr -d ' ')" -ge 1 ] || { rm -f "$tmp"; die "15 秒待ってもイベントが来なかった（$1 $2）"; }
    head -n 1 "$tmp" > "$f"; rm -f "$tmp"
    echo "保存: $f（注記なし。JSON 1 行だけ）" ;;
  *) die "知らないコマンド: $cmd" ;;
esac
