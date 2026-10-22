#!/usr/bin/env bash
# 第一次部署：解压工具链 + 解包应用产物 + 初始化数据库 + 启动后端。无需 git/编译，全程可离线（首次部署不联网）。
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec bash myhome-unix.sh --action deploy "$@"
