#!/usr/bin/env bash
# 日常启动（开机/重启后）：启动数据库与前后端。源码已就位时无需联网。
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec bash myhome-unix.sh --action start "$@"
