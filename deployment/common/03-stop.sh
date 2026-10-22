#!/usr/bin/env bash
# 停止：安全关闭数据库与前后端。数据、照片与密钥全部保留。
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec bash myhome-unix.sh --action stop "$@"
