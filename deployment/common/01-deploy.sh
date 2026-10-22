#!/usr/bin/env bash
# 第一次部署：解压工具链 + 拉取源码 + 初始化数据库 + 启动前后端。需要联网。
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec bash myhome-unix.sh --action deploy "$@"
