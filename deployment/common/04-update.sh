#!/usr/bin/env bash
# 部署最新：拉取两仓最新源码并重启前后端。需要联网。
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec bash myhome-unix.sh --action update "$@"
