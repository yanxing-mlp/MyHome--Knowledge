#!/usr/bin/env bash
# 后端「部署最新」按钮点一下 → 分离式拉起本脚本 → 以 update 动作跑引擎。
# 必须脱离后端进程组：update 会杀掉并重启后端，本脚本要在独立会话中存活，
# 并把实时进度写进 logs/deploy-status.json，重启后的新后端读同一文件接着显示。
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${FH_INSTALL_DIR:-}"
ARGS=(--action update)
[ -n "$INSTALL_DIR" ] && ARGS+=(--install-dir "$INSTALL_DIR")
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$DIR/myhome-unix.sh" "${ARGS[@]}" >/dev/null 2>&1 </dev/null &
elif command -v perl >/dev/null 2>&1; then
  perl -e 'use POSIX qw(setsid); setsid; exec @ARGV or exit 1' bash "$DIR/myhome-unix.sh" "${ARGS[@]}" >/dev/null 2>&1 </dev/null &
else
  nohup bash "$DIR/myhome-unix.sh" "${ARGS[@]}" >/dev/null 2>&1 </dev/null & disown 2>/dev/null || true
fi
exit 0
