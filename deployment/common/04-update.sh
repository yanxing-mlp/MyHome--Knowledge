#!/usr/bin/env bash
# 升级到本离线包内的版本：校验并解包本包 runtime/ 携带的产物包，SHA256 通过后原子替换 app/ 并重启后端。
# 全程离线、不下载、不 git、不现场构建。用法：拿到新的离线部署包解压后，运行本脚本（指向同一安装目录）。
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec bash myhome-unix.sh --action update "$@"
