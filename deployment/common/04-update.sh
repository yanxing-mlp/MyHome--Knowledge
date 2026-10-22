#!/usr/bin/env bash
# 部署最新：从 GitHub Release 拉取最新产物包，校验 SHA256 后原子替换 app/ 并重启后端。需要联网。
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec bash myhome-unix.sh --action update "$@"
