#!/usr/bin/env bash
# =============================================================================
# MyHome macOS(arm64) / Linux(x64) 一键部署引擎（联网 · 产物直跑）
#
# 这是 myhome-windows.ps1 的 Unix 对等实现，口径逐条对齐。v57 起从「源码直跑」改为「产物直跑」：
#   · 工具链只保留运行必需的 JDK 21 与 MySQL 8.4，随包携带并逐一校验 SHA256（不联网下载）。
#     不再需要 git / Maven / pnpm / Node —— 应用不再现场编译，直接跑构建好的产物。
#   · 应用产物（后端 fat JAR + 两份已构建前端 dist + version.json）打包成一个 zip 随包携带于
#     runtime/。首次部署把它解到 <install>/app/，用 `java -jar` 起后端；后端单端口(8080)同时托管
#     两份 dist（Topology A：/admin/** 出 B 端、/** 出 C 端），前后端同源、无需任何反向代理。
#   · 数据库迁移（Flyway）随 JAR 的 classpath 一起发布，故「部署包的 SQL」= 重新构建 JAR 即自动更新，
#     不存在独立的 .sql 文件。首次部署与每次更新都由后端启动时的 Flyway 自动应用新迁移。
#   · 「部署最新」（04-update.sh 或后端部署管理页一键触发）从 GitHub Release 拉取最新产物包，
#     校验 SHA256 后原子替换 <install>/app/，再重启后端。这一步需要联网。
#   · 私有 MySQL 监听 127.0.0.1:13306，数据落 <install>/data/mysql，绝不接管系统 MySQL。
#   · 只绑定 127.0.0.1；不改防火墙、不改全局配置、不杀未知进程、不清库、不删密钥。
#
# 用法（由 01-deploy.sh / 02-start.sh / 03-stop.sh / 04-update.sh 调用）：
#   bash myhome-unix.sh --action deploy|start|stop|update [--install-dir DIR]
# 环境变量 MYHOME_INSTALL_DIR 可替代 --install-dir。
# =============================================================================
set -euo pipefail

# ---------- 参数 ----------
ACTION="deploy"
INSTALL_DIR_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --action) ACTION="${2:-}"; shift 2 ;;
    --action=*) ACTION="${1#*=}"; shift ;;
    --install-dir) INSTALL_DIR_ARG="${2:-}"; shift 2 ;;
    --install-dir=*) INSTALL_DIR_ARG="${1#*=}"; shift ;;
    *) echo "[MyHome] 未知参数：$1" >&2; exit 2 ;;
  esac
done
case "$ACTION" in deploy|start|stop|update) ;; *) echo "[MyHome] action 必须是 deploy|start|stop|update" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 平台识别 ----------
OS_KERNEL="$(uname -s)"
OS_ARCH="$(uname -m)"
case "$OS_KERNEL" in
  Darwin) PLATFORM="macos-arm64"; EXPECT_ARCH="arm64" ;;
  Linux)  PLATFORM="linux-x64";   EXPECT_ARCH="x86_64" ;;
  *) echo "[MyHome] 仅支持 macOS 与 Linux，检测到：$OS_KERNEL" >&2; exit 1 ;;
esac
if [ "$OS_ARCH" != "$EXPECT_ARCH" ]; then
  echo "[MyHome] 本包仅支持 $PLATFORM（$EXPECT_ARCH），检测到架构：$OS_ARCH" >&2; exit 1
fi

# ---------- 端口 / 路径 ----------
# 产物直跑只有两个端口：私有 MySQL(13306) 与后端(8080)。前端两份 dist 由后端单端口托管，不再各占端口。
DB_PORT=13306
BACKEND_PORT=8080

if [ -n "$INSTALL_DIR_ARG" ]; then
  ROOT="$INSTALL_DIR_ARG"
elif [ -n "${MYHOME_INSTALL_DIR:-}" ]; then
  ROOT="$MYHOME_INSTALL_DIR"
else
  if [ "$OS_KERNEL" = "Darwin" ]; then ROOT="$HOME/Library/Application Support/MyHome"
  else ROOT="$HOME/.local/share/MyHome"; fi
fi
# 规范化（去掉尾部斜杠、展开 ~）
ROOT="${ROOT%/}"

STATE="$ROOT/state"
TOOLS="$ROOT/tools"
LOGS="$ROOT/logs"
DATA="$ROOT/data"
MYSQL_DATA="$DATA/mysql"
FILES_DIR="$DATA/files"
# 应用产物目录（解包后的 JAR + 两份 dist + version.json）；更新时整目录原子替换。
APP_DIR="$ROOT/app"
APP_NEW="$ROOT/app.new"
APP_OLD="$ROOT/app.old"
APP_VERSION_FILE="$APP_DIR/version.json"
CLIENT_FILE="$STATE/mysql-client.cnf"
INIT_FILE="$STATE/mysql-init.sql"
INI_FILE="$STATE/my.cnf"
SECRETS_FILE="$STATE/secrets.env"
RUN_LOG=""
LOCK_DIR="$STATE/operation.lock"
LOCK_ACQUIRED=0

# 运行环境（部署后写入 state/runtime.env）——产物直跑只需要 JDK 与 MySQL。
RT_JDK=""; RT_MYSQL=""; RT_JAVA_HOME=""

# 清单里 app / update 段的值（load_app_manifest 填充）
APP_ZIP_NAME="MyHome-app-payload.zip"; APP_JAR_NAME="family-home-server.jar"
APP_ADMIN_DIRNAME="admin"; APP_H5_DIRNAME="h5"
# 新库冷启动用的原始 schema+种子+真 Flyway 历史快照（构建期生成，见 gen-schema-snapshot.py）。
APP_SNAPSHOT_NAME="schema-snapshot.sql"
UPDATE_REPO=""; UPDATE_VERSION_ASSET="version.json"; UPDATE_PAYLOAD_ASSET="MyHome-app-payload.zip"

# 当前解包在 app/ 里的产物元数据（read_app_meta 从 app/version.json 读取）
APP_VERSION=""; APP_SALT=""; APP_SERVER_COMMIT=""; APP_WEB_COMMIT=""

# 最新发布版本元数据（fetch_latest_release 从 GitHub Release 的 version.json 读取）
LATEST_VERSION=""; LATEST_SHA=""; LATEST_SERVER_COMMIT=""; LATEST_WEB_COMMIT=""

# 「部署最新」进度上报（仅 action=update 启用）
DEPLOY_ACTIVE=0
DEPLOY_STATUS_PATH=""
DEPLOY_HISTORY_PATH=""
DEPLOY_RUN_ID=""
DEPLOY_STARTED_AT=""
DEPLOY_PHASE=""
DEPLOY_LINES_FILE=""
DEPLOY_FROM_SERVER=""; DEPLOY_FROM_WEB=""; DEPLOY_FROM_VERSION=""
DEPLOY_RESULT_SERVER=""; DEPLOY_RESULT_WEB=""; DEPLOY_RESULT_VERSION=""
DEPLOY_TARGET_SERVER=""; DEPLOY_TARGET_WEB=""; DEPLOY_TARGET_VERSION=""

CURRENT_STEP="检查系统和安装目录"
DIAG_FILES=()

# =============================================================================
# 诊断 / 日志 / 脱敏
# =============================================================================
redact() {
  # 绝不把密钥、SQL、凭据文件内容打到日志或终端。
  local text="$1" v
  for v in "${SECRET_VALUES[@]:-}"; do
    [ -n "${v:-}" ] && text="${text//$v/[REDACTED]}"
  done
  printf '%s' "$text"
}
SECRET_VALUES=()

log_line() {
  local safe; safe="$(redact "$1")"
  # 必须走 stderr：本脚本大量用 $(func) 捕获函数 stdout 作为返回值
  # （local_package/install_tarball/owned_pid/sha256_of/json_get/sql 等）。
  # 若日志也写 stdout，会被一并捕获、污染返回值（对齐 PS1 里 Write-Host 不进管道的语义）。
  printf '%s\n' "$safe" >&2
  if [ -n "$RUN_LOG" ]; then printf '%s\n' "$safe" >> "$RUN_LOG" 2>/dev/null || RUN_LOG=""; fi
}
info() { log_line "[MyHome] $1"; }
step() {
  CURRENT_STEP="$1"
  DIAG_FILES=()
  shift || true
  DIAG_FILES=("$@")
  info "步骤：$CURRENT_STEP"
  if [ "$DEPLOY_ACTIVE" = "1" ]; then DEPLOY_PHASE="$CURRENT_STEP"; deploy_line "步骤：$CURRENT_STEP"; fi
}
fail() {
  # 打印失败上下文（步骤 + 原因 + 相关日志尾部），保留 data/state，不自动清库重试。
  local reason="${1:-未知错误}"
  log_line ""
  log_line "[失败步骤] $CURRENT_STEP"
  log_line "[失败原因] $(redact "$reason")"
  local f
  for f in "${DIAG_FILES[@]:-}"; do
    [ -z "$f" ] && continue
    log_line "[相关日志] $f"
    if [ -f "$f" ]; then
      tail -n 40 "$f" 2>/dev/null | grep -iE 'ERROR|Caused by:|Exception|APPLICATION FAILED|Description:|Reason:|Action:|SQL State|Error Code' | tail -n 20 | while IFS= read -r ln; do
        log_line "  $(redact "$ln")"
      done || true
    fi
  done
  if [ -n "$RUN_LOG" ]; then log_line "[本次操作记录] $RUN_LOG"; fi
  log_line "请保留 data/ 和 state/；不要删库、删密钥或重新初始化来重试。"
  local launcher="01-deploy.sh"
  case "$ACTION" in start) launcher="02-start.sh";; stop) launcher="03-stop.sh";; update) launcher="04-update.sh";; esac
  log_line "修复上述原因后，重新运行 $launcher（自定义安装目录需使用相同参数）。"
}
die() { fail "$1"; exit 1; }

# =============================================================================
# 极简 JSON 读取（无 jq / python 依赖）
#   json_flat <file>  → 每行 dotted.path=value（仅字符串/数字/布尔叶子）
#   json_get  <file> <path>  → 取单个值
# 清单与 version.json 结构固定、由打包器/构建器生成，故用 awk 状态机按 { } 层级展平即可。
# =============================================================================
json_flat() {
  awk '
    function emit(k, v) {
      gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", v)
      if (v ~ /^".*"$/) { v = substr(v, 2, length(v)-2) }
      printf "%s%s=%s\n", prefix(), k, v
    }
    function prefix(   i, s) { s=""; for (i=1;i<=depth;i++){ s = s (i>1?".":"") stack[i] } return s (depth>0?".":"") }
    BEGIN { depth=0 }
    {
      line=$0
      # 逐字符扫描，处理 "key": value 与 { }
      n=length(line); i=1; key=""; inkey=0; val=""; aftercolon=0
      while (i<=n) {
        c=substr(line,i,1)
        if (c=="\"") {
          # 读一个字符串
          s=""; i++
          while (i<=n) { cc=substr(line,i,1); if (cc=="\\") { s=s substr(line,i,2); i+=2; continue } if (cc=="\"") { i++; break } s=s cc; i++ }
          if (!aftercolon) { key=s; }
          else { val = "\"" s "\"" }
          continue
        }
        if (c==":") { aftercolon=1; i++; continue }
        if (c=="{" || c=="[") {
          if (key!="") { depth++; stack[depth]=key; key=""; aftercolon=0 }
          i++; continue
        }
        if (c=="}" || c=="]") { if (key!="" && val!="") { emit(key, val) } key=""; val=""; if (depth>0) depth--; aftercolon=0; i++; continue }
        if (c==",") { if (key!="" && val!="") { emit(key, val) } key=""; val=""; aftercolon=0; i++; continue }
        if (aftercolon && (c ~ /[0-9a-zA-Z._-]/)) {
          s=""; while (i<=n) { cc=substr(line,i,1); if (cc ~ /[0-9a-zA-Z._-]/) { s=s cc; i++ } else break }
          val=s; continue
        }
        i++
      }
      if (key!="" && val!="") { emit(key, val) }
    }
  ' "$1"
}
json_get() { json_flat "$1" | awk -F= -v p="$2" '$1==p { sub(/^[^=]*=/,""); print; exit }'; }

# =============================================================================
# 校验 / 安全路径 / 哈希
# =============================================================================
sha256_of() { # sha256_of <file> → 打印十六进制摘要（Linux 优先 sha256sum，macOS 用 shasum）
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "缺少 sha256sum / shasum，无法校验文件完整性；请安装其中之一后重试。"; fi
}
check_hash() { # check_hash <file> <expected>
  [ -f "$1" ] || return 1
  [ "$(sha256_of "$1")" = "$2" ]
}

# 拒绝越界路径（解压目标必须落在 base 内）
safe_path() { # safe_path <base> <relative>
  local base="$1" rel="$2"
  case "$rel" in /*|"") return 1 ;; esac
  case "$rel" in *..*) return 1 ;; esac
  printf '%s/%s' "$base" "$rel"
}

local_package() { # local_package <spec-key>  → 打印 runtime 内文件绝对路径（校验 SHA256）
  local key="$1" file hash algo pkg="$SCRIPT_DIR/packages.json"
  file="$(json_get "$pkg" "$key.file")"
  hash="$(json_get "$pkg" "$key.hash")"
  algo="$(json_get "$pkg" "$key.algorithm")"
  if [ "$algo" != "SHA256" ] || ! printf '%s' "$hash" | grep -qE '^[a-fA-F0-9]{64}$'; then
    die "一键部署包清单 $key 缺少有效 SHA256；请重新完整拷贝一键部署包。"
  fi
  case "$file" in */*) die "runtime 清单 $key.file 必须是文件名，不能含目录。" ;; esac
  local path="$SCRIPT_DIR/runtime/$file"
  step "校验本地文件 runtime/$file"
  if ! check_hash "$path" "$hash"; then
    die "本地文件缺失或 SHA256 不符：runtime/$file。请重新完整拷贝一键部署包（含 runtime/）；不联网下载。"
  fi
  printf '%s' "$path"
}

install_tarball() { # install_tarball <spec-key> <name>  → 打印安装后的 tools/<name> 目录
  local key="$1" name="$2"
  local archive directory probe home
  archive="$(local_package "$key")"
  directory="$(json_get "$SCRIPT_DIR/packages.json" "$key.directory")"
  probe="$(json_get "$SCRIPT_DIR/packages.json" "$key.probe")"
  home="$(json_get "$SCRIPT_DIR/packages.json" "$key.home")"
  step "检查 $name 运行环境"
  local runtime_home="$TOOLS/$name"
  local stamp="$runtime_home/.package-hash"
  local hash; hash="$(json_get "$SCRIPT_DIR/packages.json" "$key.hash")"
  if [ -f "$stamp" ] && [ -e "$runtime_home/$probe" ]; then
    if [ "$(cat "$stamp")" != "$hash" ]; then
      die "已安装的 $name 与本包不一致；不要在运行中的数据库上替换运行环境。"
    fi
    printf '%s' "$runtime_home"; return 0
  fi
  step "解压并安装 $name"
  local staging="$TOOLS/$name.extract"
  rm -rf "$staging"; mkdir -p "$staging"
  # tar -xf 自动识别 .gz/.xz（bsdtar 与 GNU tar 皆支持）
  tar -xf "$archive" -C "$staging" || die "解压 $name 失败：$archive"
  local top="$staging"
  if [ -n "$directory" ]; then
    top="$(safe_path "$staging" "$directory")" || die "清单 $key.directory 不安全：$directory"
  fi
  if [ ! -e "$top/$probe" ]; then die "$name 归档不完整（缺少 $probe）。"; fi
  if [ -e "$runtime_home" ]; then
    die "运行环境目录不完整：$runtime_home。请保留 data/state，仅删除这个不完整的 tools 子目录后重试。"
  fi
  mv "$top" "$runtime_home"
  printf '%s' "$hash" > "$stamp"
  rm -rf "$staging"
  # macOS：清除下载可能带来的隔离属性，避免 Gatekeeper 拦截命令行二进制（无该属性时无害）。
  if [ "$OS_KERNEL" = "Darwin" ]; then xattr -dr com.apple.quarantine "$runtime_home" 2>/dev/null || true; fi
  chmod +x "$runtime_home/bin/"* 2>/dev/null || true
  printf '%s' "$runtime_home"
}

# =============================================================================
# 应用产物：解包 / 读取元数据 / 从 GitHub Release 拉取最新
# =============================================================================
load_app_manifest() {
  # 从 packages.json 读 app / update 段（不校验格式，格式校验在 main 里针对 deploy/update 做）。
  local pkg="$SCRIPT_DIR/packages.json"
  [ -f "$pkg" ] || return 0
  local v
  v="$(json_get "$pkg" app.file)";            [ -n "$v" ] && APP_ZIP_NAME="$v"
  v="$(json_get "$pkg" app.jar)";             [ -n "$v" ] && APP_JAR_NAME="$v"
  v="$(json_get "$pkg" app.adminDir)";        [ -n "$v" ] && APP_ADMIN_DIRNAME="$v"
  v="$(json_get "$pkg" app.h5Dir)";           [ -n "$v" ] && APP_H5_DIRNAME="$v"
  v="$(json_get "$pkg" update.repo)";         [ -n "$v" ] && UPDATE_REPO="$v"
  v="$(json_get "$pkg" update.versionAsset)"; [ -n "$v" ] && UPDATE_VERSION_ASSET="$v"
  v="$(json_get "$pkg" update.payloadAsset)"; [ -n "$v" ] && UPDATE_PAYLOAD_ASSET="$v"
}

extract_app() { # extract_app <zip> <destDir>
  # 用随包的 JDK 自带的 jar 工具解 zip（跨 macOS/Linux 一致，不依赖系统 unzip）。
  local zip="$1" dest="$2" jarbin="$RT_JAVA_HOME/bin/jar"
  [ -x "$jarbin" ] || die "JDK 不完整（缺 $jarbin），无法解包应用产物。"
  rm -rf "$dest"; mkdir -p "$dest"
  ( cd "$dest" && "$jarbin" -xf "$zip" ) || die "解压应用产物包失败：$zip"
  [ -f "$dest/$APP_JAR_NAME" ] || die "产物包缺少 $APP_JAR_NAME；产物包不完整或结构不符。"
  [ -f "$dest/$APP_ADMIN_DIRNAME/index.html" ] || die "产物包缺少 $APP_ADMIN_DIRNAME/index.html（B 端 dist）。"
  [ -f "$dest/$APP_H5_DIRNAME/index.html" ] || die "产物包缺少 $APP_H5_DIRNAME/index.html（C 端 dist）。"
  [ -f "$dest/version.json" ] || die "产物包缺少 version.json；无法确定版本与传输盐。"
}

read_app_meta() { # 从当前 app/version.json 读取版本 / 传输盐 / 两仓 commit
  [ -f "$APP_VERSION_FILE" ] || die "应用目录缺少 version.json（$APP_VERSION_FILE）；请重新运行 01-deploy.sh。"
  APP_VERSION="$(json_get "$APP_VERSION_FILE" version)"
  APP_SALT="$(json_get "$APP_VERSION_FILE" transportSalt)"
  APP_SERVER_COMMIT="$(json_get "$APP_VERSION_FILE" server.commit)"
  APP_WEB_COMMIT="$(json_get "$APP_VERSION_FILE" web.commit)"
  [ -n "$APP_VERSION" ] || die "app/version.json 缺少 version 字段。"
  # 传输盐是随 dist 构建期烘焙的固定公开值（32 位十六进制）；后端运行时必须用同一个值，否则全站登录解密失败。
  printf '%s' "$APP_SALT" | grep -qE '^[a-fA-F0-9]{32}$' \
    || die "app/version.json 的 transportSalt 不是 32 位十六进制；产物包损坏或与 dist 不同源。"
}

install_app() { # 首次部署：解包随包携带的产物 zip 到 app/
  local zip; zip="$(local_package app)"
  step "解包应用产物（后端 JAR + 两份前端 dist）"
  extract_app "$zip" "$APP_DIR"
  read_app_meta
  info "已就位应用版本：$APP_VERSION"
}

release_url() { printf 'https://github.com/%s/releases/latest/download/%s' "$UPDATE_REPO" "$1"; }

fetch_latest_release() { # 拉取 GitHub 最新 Release 的 version.json（走稳定重定向，无需解析 Release API）
  printf '%s' "$UPDATE_REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
    || die "清单 update.repo 不合法（应为 owner/name）；请重新完整拷贝一键部署包。"
  command -v curl >/dev/null 2>&1 || die "未找到 curl，无法联网获取最新发布版本；请安装 curl 后重试。"
  step "查询 GitHub 最新发布版本（$UPDATE_REPO）"
  local vurl tmpv; vurl="$(release_url "$UPDATE_VERSION_ASSET")"; tmpv="$STATE/latest-version.json"
  rm -f "$tmpv"
  curl -fsSL --max-time 30 -o "$tmpv" "$vurl" \
    || die "无法获取最新发布版本信息（$vurl）；请检查网络，或确认该仓库已发布带 $UPDATE_VERSION_ASSET 资产的 Release。"
  LATEST_VERSION="$(json_get "$tmpv" version)"
  LATEST_SHA="$(json_get "$tmpv" payload.sha256)"
  LATEST_SERVER_COMMIT="$(json_get "$tmpv" server.commit)"
  LATEST_WEB_COMMIT="$(json_get "$tmpv" web.commit)"
  [ -n "$LATEST_VERSION" ] || die "最新发布的 version.json 缺少 version 字段。"
  printf '%s' "$LATEST_SHA" | grep -qE '^[a-fA-F0-9]{64}$' \
    || die "最新发布的 version.json 缺少有效的 payload.sha256；拒绝下载来源不明的产物包。"
  info "最新发布版本：$LATEST_VERSION（当前运行：${APP_VERSION:-未知}）"
}

download_release_payload() { # 下载并校验最新产物包到 state/download-payload.zip（校验通过前绝不触碰 app/）
  command -v curl >/dev/null 2>&1 || die "未找到 curl，无法下载最新产物包。"
  step "下载最新产物包（$UPDATE_PAYLOAD_ASSET）"
  local purl tmpzip; purl="$(release_url "$UPDATE_PAYLOAD_ASSET")"; tmpzip="$STATE/download-payload.zip"
  rm -f "$tmpzip"
  curl -fSL --max-time 900 -o "$tmpzip" "$purl" \
    || die "下载最新产物包失败（$purl）；请检查网络后重试。现有应用未改动。"
  step "校验产物包 SHA256"
  local actual; actual="$(sha256_of "$tmpzip")"
  [ "$actual" = "$LATEST_SHA" ] \
    || die "下载的产物包 SHA256（$actual）与 version.json 声明的（$LATEST_SHA）不符；已丢弃，现有应用未改动。"
  printf '%s' "$tmpzip"
}

swap_app() { # swap_app <newDir>  → 原子替换 app/（调用前后端必须已停止）
  local newdir="$1"
  rm -rf "$APP_OLD"
  if [ -d "$APP_DIR" ]; then mv "$APP_DIR" "$APP_OLD"; fi
  mv "$newdir" "$APP_DIR"
  rm -rf "$APP_OLD"
}

# 「部署最新」的完整下载-校验-替换流程（不含停/起后端，由 main 编排）。返回 0=已替换，1=已是最新无需替换。
run_update() {
  read_app_meta
  DEPLOY_FROM_SERVER="$APP_SERVER_COMMIT"; DEPLOY_FROM_WEB="$APP_WEB_COMMIT"; DEPLOY_FROM_VERSION="$APP_VERSION"
  deploy_line "当前运行版本：$APP_VERSION"
  fetch_latest_release
  DEPLOY_TARGET_SERVER="$LATEST_SERVER_COMMIT"; DEPLOY_TARGET_WEB="$LATEST_WEB_COMMIT"; DEPLOY_TARGET_VERSION="$LATEST_VERSION"
  if [ "$LATEST_VERSION" = "$APP_VERSION" ]; then
    deploy_line "已是最新版本（$APP_VERSION），无需替换产物"
    DEPLOY_RESULT_VERSION="$APP_VERSION"; DEPLOY_RESULT_SERVER="$APP_SERVER_COMMIT"; DEPLOY_RESULT_WEB="$APP_WEB_COMMIT"
    return 1
  fi
  deploy_line "发现新版本：$APP_VERSION → $LATEST_VERSION，开始下载"
  local zip; zip="$(download_release_payload)"
  step "解包新版本到暂存目录并原子替换"
  rm -rf "$APP_NEW"
  extract_app "$zip" "$APP_NEW"
  swap_app "$APP_NEW"
  rm -f "$STATE/download-payload.zip" "$STATE/latest-version.json"
  read_app_meta
  DEPLOY_RESULT_VERSION="$APP_VERSION"; DEPLOY_RESULT_SERVER="$APP_SERVER_COMMIT"; DEPLOY_RESULT_WEB="$APP_WEB_COMMIT"
  local iat; iat="$(json_get "$STATE/installed.json" installedAt)"
  write_installed "$APP_VERSION" "$APP_SERVER_COMMIT" "$APP_WEB_COMMIT" "$iat" "$(now_iso)"
  deploy_line "已切换到新版本：$APP_VERSION（后端 ${APP_SERVER_COMMIT:0:7}、前端 ${APP_WEB_COMMIT:0:7}）"
  return 0
}

# =============================================================================
# 密钥（Unix 无 DPAPI：用 0600 文件 + 0700 目录，靠文件系统权限保护）
#   产物直跑下传输盐是随 dist 烘焙的固定公开值（见 read_app_meta），不再是逐安装随机的密钥，
#   故这里只生成/保管 DbRoot/DbApp/Vault/Auth 四把真随机密钥。
# =============================================================================
rand_b64() { head -c "$1" /dev/urandom | base64 | tr -d '\n'; }

load_secrets() {
  DbRoot=""; DbApp=""; Vault=""; Auth=""
  if [ ! -f "$SECRETS_FILE" ]; then
    if [ -d "$MYSQL_DATA/mysql" ] || [ -f "$STATE/installed.json" ]; then
      die "已有安装但缺少密钥文件。请恢复 state/secrets.env；绝不在已有数据上重新生成 vault 密钥。"
    fi
    DbRoot="$(rand_b64 36)"; DbApp="$(rand_b64 36)"
    Vault="$(rand_b64 32)"; Auth="$(rand_b64 48)"
    local tmp="$SECRETS_FILE.tmp"
    {
      printf 'DbRoot=%s\n' "$DbRoot"
      printf 'DbApp=%s\n' "$DbApp"
      printf 'Vault=%s\n' "$Vault"
      printf 'Auth=%s\n' "$Auth"
    } > "$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$SECRETS_FILE"
  fi
  # 读取（仅取已知键，值不含空格/换行）。旧安装可能残留 Transport= 行，忽略即可。
  while IFS='=' read -r k v; do
    case "$k" in
      DbRoot) DbRoot="$v";; DbApp) DbApp="$v";; Vault) Vault="$v";; Auth) Auth="$v";;
    esac
  done < "$SECRETS_FILE"
  local key
  for key in DbRoot DbApp Vault Auth; do
    eval "local val=\${$key}"
    [ -n "$val" ] || die "无法读取安装凭据（$key 为空）。请使用原电脑上的原账号，不要删除 state/secrets.env。"
  done
  SECRET_VALUES=("$DbRoot" "$DbApp" "$Vault" "$Auth")
}

# =============================================================================
# 端口 / 进程管理
# =============================================================================
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1; }
assert_port_free() {
  if port_in_use "$1"; then
    die "本机端口 $1 已被占用；不会结束其他软件的进程。请释放该端口后重试。"
  fi
}

# 读取某服务的 pid（校验仍属于我们启动的进程，避免误杀回收的 PID）
owned_pid() { # owned_pid <name>  → 打印 pid 或空
  local name="$1" pidfile="$STATE/$1.pid" cmdfile="$STATE/$1.cmd"
  [ -f "$pidfile" ] || return 0
  local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pidfile" "$cmdfile"; return 0
  fi
  # 校验命令行包含记录的标记（工具路径片段），不符则拒绝操作
  if [ -f "$cmdfile" ]; then
    local marker actual
    marker="$(cat "$cmdfile")"
    actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [ -n "$marker" ] && [ "${actual#*"$marker"}" = "$actual" ]; then
      die "$name 的 PID 记录已失效（$pid 不是本安装器启动的进程）；拒绝停止或接管。请核实后删除 $pidfile。"
    fi
  fi
  printf '%s' "$pid"
}

start_owned() { # start_owned <name> <marker> <cmd...>
  local name="$1" marker="$2"; shift 2
  local existing; existing="$(owned_pid "$name")"
  if [ -n "$existing" ]; then printf '%s' "$existing"; return 0; fi
  local suffix
  for suffix in out err; do
    local lg="$LOGS/$name.$suffix.log"
    [ -f "$lg" ] && mv "$lg" "$lg.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  done
  # set -m 让后台任务成为独立进程组组长（PGID==PID），便于整树停止。
  set -m
  "$@" >"$LOGS/$name.out.log" 2>"$LOGS/$name.err.log" &
  local pid=$!
  set +m
  # 立即退出检测
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    die "$name 启动后立即退出；请查看 $LOGS/$name.err.log。"
  fi
  printf '%s' "$pid" > "$STATE/$name.pid"
  printf '%s' "$marker" > "$STATE/$name.cmd"
  printf '%s' "$pid"
}

stop_owned() { # stop_owned <name>
  local name="$1"
  step "停止 $name 服务" "$LOGS/$name.err.log" "$LOGS/$name.out.log"
  local pid; pid="$(owned_pid "$name")"
  [ -z "$pid" ] && return 0
  info "Stopping $name ..."
  # 先优雅终止整个进程组，再强制；只动这个已校验 PID 的组，绝不按端口/名字搜杀。
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then die "$name 未能停止；未触碰其他进程。"; fi
  fi
  rm -f "$STATE/$name.pid" "$STATE/$name.cmd"
}

detach() { # detach <cmd...>  → 在新会话中分离运行（部署 launcher 必须逃离后端进程组）
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 </dev/null &
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'use POSIX qw(setsid); setsid; exec @ARGV or exit 1' "$@" >/dev/null 2>&1 </dev/null &
  else
    nohup "$@" >/dev/null 2>&1 </dev/null & disown || true
  fi
}

# =============================================================================
# 部署进度上报（仅 update）——写 logs/deploy-status.json，终态追加 logs/deploy-history.json
# =============================================================================
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

init_deploy_status() {
  DEPLOY_RUN_ID="${FH_DEPLOY_RUN_ID:-$(rand_b64 12 | tr -dc 'a-z0-9' | head -c 16)}"
  [ -n "$DEPLOY_RUN_ID" ] || DEPLOY_RUN_ID="run-$(date +%s)"
  DEPLOY_STATUS_PATH="$LOGS/deploy-status.json"
  DEPLOY_HISTORY_PATH="$LOGS/deploy-history.json"
  DEPLOY_LINES_FILE="$LOGS/.deploy-lines.$$"
  : > "$DEPLOY_LINES_FILE"
  DEPLOY_STARTED_AT="$(now_iso)"
  DEPLOY_PHASE="开始部署最新版本"
  DEPLOY_ACTIVE=1
  deploy_line "部署脚本已启动：从 GitHub Release 拉取最新产物包 + 重启后端"
}

deploy_line() { # deploy_line <message> [level]
  [ "$DEPLOY_ACTIVE" = "1" ] || return 0
  local msg; msg="$(json_escape "$(redact "$1")")"
  local level="${2:-info}"
  printf '{"ts":"%s","message":"%s","level":"%s"}\n' "$(now_iso)" "$msg" "$level" >> "$DEPLOY_LINES_FILE"
  write_deploy_status "running" ""
}

write_deploy_status() { # write_deploy_status <status> [error]
  [ "$DEPLOY_ACTIVE" = "1" ] && [ -n "$DEPLOY_STATUS_PATH" ] || return 0
  local status="$1" err="${2:-}"
  local finished="null"; [ "$status" != "running" ] && finished="\"$(now_iso)\""
  local errjson="null"; [ -n "$err" ] && errjson="\"$(json_escape "$(redact "$err")")\""
  local lines="[]"
  if [ -f "$DEPLOY_LINES_FILE" ]; then lines="[$(paste -sd, "$DEPLOY_LINES_FILE")]"; fi
  local tmp="$DEPLOY_STATUS_PATH.tmp"
  {
    printf '{'
    printf '"runId":"%s",' "$DEPLOY_RUN_ID"
    printf '"status":"%s",' "$status"
    printf '"phase":"%s",' "$(json_escape "$DEPLOY_PHASE")"
    printf '"startedAt":"%s",' "$DEPLOY_STARTED_AT"
    printf '"finishedAt":%s,' "$finished"
    printf '"error":%s,' "$errjson"
    printf '"fromVersion":"%s",' "$(json_escape "$DEPLOY_FROM_VERSION")"
    printf '"targetVersion":"%s",' "$(json_escape "$DEPLOY_TARGET_VERSION")"
    printf '"resultVersion":"%s",' "$(json_escape "$DEPLOY_RESULT_VERSION")"
    printf '"fromCommits":{"server":"%s","web":"%s"},' "$DEPLOY_FROM_SERVER" "$DEPLOY_FROM_WEB"
    printf '"targetCommits":{"server":"%s","web":"%s"},' "$DEPLOY_TARGET_SERVER" "$DEPLOY_TARGET_WEB"
    printf '"resultCommits":{"server":"%s","web":"%s"},' "$DEPLOY_RESULT_SERVER" "$DEPLOY_RESULT_WEB"
    printf '"lines":%s' "$lines"
    printf '}\n'
  } > "$tmp" 2>/dev/null && mv "$tmp" "$DEPLOY_STATUS_PATH" 2>/dev/null || true
  if [ "$status" != "running" ]; then append_deploy_history || true; fi
}

append_deploy_history() {
  [ -n "$DEPLOY_HISTORY_PATH" ] || return 0
  local record; record="$(cat "$DEPLOY_STATUS_PATH" 2>/dev/null)"
  [ -n "$record" ] || return 0
  local tmp="$DEPLOY_HISTORY_PATH.tmp"
  # 新记录前插，按 runId 去重，最多 50 条。用 awk 处理既有数组（无 jq）。
  local existing="[]"
  [ -f "$DEPLOY_HISTORY_PATH" ] && existing="$(cat "$DEPLOY_HISTORY_PATH")"
  printf '%s' "$existing" > "$tmp.prev"
  printf '%s' "$record" > "$tmp.rec"
  awk -v recfile="$tmp.rec" '
    BEGIN { rec=""; while ((getline l < recfile) > 0) rec = rec l; close(recfile) }
    { buf = buf $0 }
    END {
      gsub(/^[ \t\r\n\[]+/, "", buf); gsub(/[ \t\r\n\]]+$/, "", buf)
      if (buf == "") { print "[" rec "]"; exit }
      print "[" rec "," buf "]"
    }
  ' "$tmp.prev" > "$tmp" 2>/dev/null && mv "$tmp" "$DEPLOY_HISTORY_PATH" 2>/dev/null || true
  rm -f "$tmp.prev" "$tmp.rec"
}

# =============================================================================
# MySQL
# =============================================================================
write_mysql_config() {
  local base="$RT_MYSQL" data="$MYSQL_DATA" errlog="$LOGS/mysql-error.log" sock="$MYSQL_DATA/mysql.sock"
  # Unix 域套接字路径有 ~104 字节硬上限；超了 mysqld 直接 abort（错误信息隐晦）。
  # 安装目录过深会触发，提前拦截并给出可操作指引（默认安装路径足够短，不受影响）。
  if [ "${#sock}" -gt 100 ]; then
    die "安装路径过深，MySQL 套接字路径超出系统上限（${#sock} 字符）：$sock。请改用更短的 --install-dir（例如 \$HOME/MyHome）后重新部署。"
  fi
  cat > "$INI_FILE" <<EOF
[mysqld]
basedir=$base
datadir=$data
port=$DB_PORT
bind-address=127.0.0.1
socket=$sock
mysqlx=0
character-set-server=utf8mb4
collation-server=utf8mb4_0900_ai_ci
max_allowed_packet=64M
innodb_buffer_pool_size=128M
skip-log-bin
general_log=OFF
log-error=$errlog
pid-file=$data/mysql.pid
EOF
  chmod 600 "$INI_FILE"
  cat > "$CLIENT_FILE" <<EOF
[client]
user=root
password="$DbRoot"
host=127.0.0.1
port=$DB_PORT
protocol=TCP
default-character-set=utf8mb4
EOF
  chmod 600 "$CLIENT_FILE"
}

sql() { # sql <statement>  → 打印结果
  "$RT_MYSQL/bin/mysql" "--defaults-extra-file=$CLIENT_FILE" --batch --skip-column-names --connect-timeout=5 <<< "$1"
}

ensure_database() {
  step "初始化并启动 MySQL 数据库" "$LOGS/mysql-error.log" "$LOGS/mysql.err.log"
  write_mysql_config
  local pid; pid="$(owned_pid mysql)"
  if [ -z "$pid" ]; then
    assert_port_free "$DB_PORT"
    local mysqld="$RT_MYSQL/bin/mysqld"
    if [ ! -d "$MYSQL_DATA/mysql" ]; then
      if [ -f "$STATE/mysql-initialized" ] || [ -f "$STATE/mysql-secured" ] || [ -f "$STATE/schema-stage-one" ]; then
        die "已有 MySQL 数据缺失。请一并恢复 data 与 state；拒绝初始化一个空的替代库。"
      fi
      if [ -n "$(ls -A "$MYSQL_DATA" 2>/dev/null)" ]; then
        die "MySQL 数据目录已被部分初始化。请勿盲目删除 data；先查看 logs/mysql-error.log。"
      fi
      info "Initializing a private MySQL database ..."
      "$mysqld" "--defaults-file=$INI_FILE" --initialize-insecure >>"$LOGS/mysql-init.out.log" 2>&1 \
        || die "MySQL 初始化失败；请查看 logs/mysql-error.log。"
    fi
    printf '1' > "$STATE/mysql-initialized"
    local -a mysql_args=("--defaults-file=$INI_FILE")
    if [ ! -f "$STATE/mysql-secured" ]; then
      # init-file 在接受客户端连接前执行；口令不出现在命令行。
      cat > "$INIT_FILE" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DbRoot';
CREATE DATABASE IF NOT EXISTS family_home CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS 'myhome'@'localhost' IDENTIFIED BY '$DbApp';
GRANT ALL PRIVILEGES ON family_home.* TO 'myhome'@'localhost';
EOF
      chmod 600 "$INIT_FILE"
      mysql_args+=("--init-file=$INIT_FILE")
    fi
    pid="$(start_owned mysql "$RT_MYSQL/bin/mysqld" "$mysqld" "${mysql_args[@]}")"
  fi
  local ready=0 i last="SELECT 1 尚未返回预期结果。"
  for i in $(seq 1 90); do
    if ! kill -0 "$pid" 2>/dev/null; then die "MySQL 进程已退出。最后连接结果：$last"; fi
    if [ "$(sql 'SELECT 1;' 2>/dev/null || true)" = "1" ]; then ready=1; break; fi
    last="MySQL 尚未就绪"
    sleep 2
  done
  [ "$ready" = "1" ] || die "MySQL 启动检查超时。最后连接结果：$last"
  if [ "$(sql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='family_home';")" != "1" ]; then
    die "受管数据库缺失；请恢复它而不是静默重新初始化。"
  fi
  load_schema_snapshot_if_empty
  printf '1' > "$STATE/mysql-secured"
  rm -f "$INIT_FILE"
}

# 新库冷启动：family_home 零表时先 load 构建期快照（结构+种子+真 Flyway history），再起后端。
# 为什么需要：空库若直接让后端 Flyway 按版本号严格重放，会炸在 V103（file 域 V1xx 却引用 album/recipe 表）。
# 快照里已含完整 flyway_schema_history，后端起来即「validated 59 / up to date / no migration necessary」。
# 已有库（升级路径）零表判定不成立 → 跳过，Flyway 增量迁移，行为不变、绝不覆盖既有数据。
load_schema_snapshot_if_empty() {
  local tbl_count; tbl_count="$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='family_home';")"
  if [ "$tbl_count" != "0" ]; then
    info "Database already has $tbl_count table(s); skipping snapshot load (incremental Flyway will run instead)."
    return 0
  fi
  local snap="$APP_DIR/$APP_SNAPSHOT_NAME"
  if [ ! -f "$snap" ]; then
    die "family_home 为空但缺少 schema 快照（$snap）；无法安全初始化新库。请用完整产物重新运行 01-deploy.sh。"
  fi
  step "空库冷启动：载入原始 schema 快照（含真 Flyway 历史）" "$LOGS/mysql-error.log"
  info "Loading pristine schema snapshot into empty family_home ..."
  "$RT_MYSQL/bin/mysql" "--defaults-extra-file=$CLIENT_FILE" --default-character-set=utf8mb4 family_home < "$snap" \
    || die "schema 快照载入失败；请查看 logs/mysql-error.log。"
  local hist; hist="$(sql "SELECT COUNT(*) FROM family_home.flyway_schema_history WHERE success=1;" 2>/dev/null || echo 0)"
  [ "$hist" -gt 0 ] 2>/dev/null || die "快照载入后 flyway_schema_history 为空；快照可能损坏，拒绝继续。"
  printf '1' > "$STATE/schema-snapshot-loaded"
  info "Snapshot loaded ($hist migrations recorded). Backend Flyway will validate and no-op."
}

stop_database() {
  step "安全停止 MySQL 数据库" "$LOGS/mysql-error.log" "$LOGS/mysql.err.log"
  local had_record=0; [ -f "$STATE/mysql.pid" ] && had_record=1
  local pid; pid="$(owned_pid mysql)"
  if [ -z "$pid" ]; then
    [ "$had_record" = "1" ] && rm -f "$INIT_FILE"
    return 0
  fi
  write_mysql_config
  info "Shutting down MySQL safely ..."
  "$RT_MYSQL/bin/mysqladmin" "--defaults-extra-file=$CLIENT_FILE" --connect-timeout=10 shutdown >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then die "MySQL 仍在关闭中；请勿强制断电。"; fi
  rm -f "$STATE/mysql.pid" "$STATE/mysql.cmd" "$INIT_FILE"
}

# =============================================================================
# 后端启动（java -jar，单端口托管两份 dist）
# =============================================================================
clean_dev_env() {
  # 与 Windows 一致：继承来的开发者 datasource/config/JVM 变量绝不能带进 prod。
  local vars
  vars="$(env | grep -oE '^(SPRING_[A-Za-z0-9_]*|FH_[A-Za-z0-9_]*|MYSQL_[A-Za-z0-9_]*|SERVER_[A-Za-z0-9_]*|LOGGING_[A-Za-z0-9_]*|JAVA_TOOL_OPTIONS|JDK_JAVA_OPTIONS|_JAVA_OPTIONS|JAVA_OPTS|JAVA_HOME|MAVEN_OPTS)=' | sed 's/=$//' || true)"
  local v
  for v in $vars; do unset "$v" 2>/dev/null || true; done
}

wait_backend() { # wait_backend <pid>
  local pid="$1" i last="健康接口尚未返回结果。" body
  for i in $(seq 1 300); do
    if ! kill -0 "$pid" 2>/dev/null; then die "后端进程已退出。最后健康检查：$last"; fi
    body="$(curl -fsS --max-time 3 "http://127.0.0.1:$BACKEND_PORT/api/b/health" 2>/dev/null || true)"
    if printf '%s' "$body" | grep -q '"app":"family-home-server"' && printf '%s' "$body" | grep -q '"db":"MySQL'; then
      return 0
    fi
    [ -n "$body" ] && last="健康检查未通过：$(redact "$body")"
    sleep 2
  done
  die "后端健康检查超时。最后检查结果：$last"
}

start_backend_logged() {
  assert_port_free "$BACKEND_PORT"
  [ -f "$APP_DIR/$APP_JAR_NAME" ] || die "应用产物缺失（$APP_DIR/$APP_JAR_NAME）；请先运行 01-deploy.sh。"
  [ -n "$APP_SALT" ] || read_app_meta
  for suffix in out err; do
    local lg="$LOGS/backend.$suffix.log"
    [ -f "$lg" ] && mv "$lg" "$lg.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  done
  local java="$RT_JAVA_HOME/bin/java"
  set -m
  (
    clean_dev_env
    export JAVA_HOME="$RT_JAVA_HOME"
    export PATH="$RT_JAVA_HOME/bin:$PATH"
    export SPRING_PROFILES_ACTIVE=prod
    export MYSQL_HOST=127.0.0.1 MYSQL_PORT="$DB_PORT" MYSQL_DATABASE=family_home MYSQL_USER=myhome MYSQL_PASSWORD="$DbApp"
    export FH_VAULT_PASSWORD_KEY="$Vault" FH_TRANSPORT_CRYPTO_SALT="$APP_SALT" FH_AUTH_TOKEN_SECRET="$Auth"
    export FH_STORAGE_ROOT="$FILES_DIR"
    # 单端口托管：后端把这两个目录当静态资源发出（/admin/** 与 /**）。留空则不启用（开发机口径）。
    export FH_WEB_ADMIN_DIR="$APP_DIR/$APP_ADMIN_DIRNAME"
    export FH_WEB_H5_DIR="$APP_DIR/$APP_H5_DIRNAME"
    export LOGGING_FILE_NAME="$LOGS/server.log"
    export SERVER_ADDRESS=127.0.0.1 SERVER_PORT="$BACKEND_PORT"
    # 变更记录页「当前运行版本」= 本次产物构建自的两仓 commit（取自 app/version.json，产物直跑没有 git 工作副本）。
    export FH_RUNNING_COMMIT_SERVER="$APP_SERVER_COMMIT" FH_RUNNING_COMMIT_WEB="$APP_WEB_COMMIT"
    # 「部署最新」入口：后端据此分离式拉起 deploy-now.sh + 读它写出的进度/历史文件；缺 launcher/progress-file 即视为未接入。
    export FH_DEPLOY_LAUNCHER="$SCRIPT_DIR/deploy-now.sh"
    export FH_DEPLOY_PROGRESS_FILE="$LOGS/deploy-status.json"
    export FH_DEPLOY_HISTORY_FILE="$LOGS/deploy-history.json"
    export FH_DEPLOY_RELEASE_REPO="$UPDATE_REPO"
    export FH_INSTALL_DIR="$ROOT"
    export FH_MYSQLDUMP_PATH="$RT_MYSQL/bin/mysqldump"
    # Flyway 的位置/乱序/基线策略全部沿用 JAR 内 application.yml（已验证的 prod 口径），此处不再覆盖。
    exec "$java" -Dfile.encoding=UTF-8 -jar "$APP_DIR/$APP_JAR_NAME"
  ) >"$LOGS/backend.out.log" 2>"$LOGS/backend.err.log" &
  local pid=$!
  set +m
  sleep 1
  kill -0 "$pid" 2>/dev/null || die "后端启动后立即退出；请查看 $LOGS/backend.err.log。"
  printf '%s' "$pid" > "$STATE/backend.pid"
  printf '%s' "$APP_JAR_NAME" > "$STATE/backend.cmd"
  wait_backend "$pid"
}

# =============================================================================
# 安装身份 / 运行环境记录
# =============================================================================
assert_artifact_install() { # assert_artifact_install [require]
  local require="${1:-}"
  local record="$STATE/installed.json"
  if [ -f "$record" ]; then
    local fv rm
    fv="$(json_get "$record" formatVersion)"; rm="$(json_get "$record" runMode)"
    if [ "$fv" != "4" ] || [ "$rm" != "artifact" ]; then
      die "现有安装不是本「一键部署包（产物直跑）」安装的（可能是旧版源码/离线包）；拒绝接管，请保留 data/ 和 state/。"
    fi
    return 0
  fi
  [ "$require" = "require" ] && die "尚未部署应用产物，请先运行 01-deploy.sh。"
  return 0
}

write_installed() { # write_installed <version> <server_commit> <web_commit> <installedAt> [updatedAt]
  local ver="$1" sc="$2" wc="$3" iat="$4" uat="${5:-}"
  local tmp="$STATE/installed.json.tmp"
  {
    printf '{'
    printf '"formatVersion":4,"offline":false,"runMode":"artifact",'
    printf '"version":"%s",' "$(json_escape "$ver")"
    printf '"server":{"commit":"%s"},' "$sc"
    printf '"web":{"commit":"%s"},' "$wc"
    printf '"installedAt":"%s"' "$iat"
    [ -n "$uat" ] && printf ',"updatedAt":"%s"' "$uat"
    printf '}\n'
  } > "$tmp" && mv "$tmp" "$STATE/installed.json"
}

write_runtime_env() {
  local tmp="$STATE/runtime.env.tmp"
  {
    printf 'RT_JDK=%q\n' "$RT_JDK"
    printf 'RT_JAVA_HOME=%q\n' "$RT_JAVA_HOME"
    printf 'RT_MYSQL=%q\n' "$RT_MYSQL"
  } > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$STATE/runtime.env"
}
load_runtime_env() {
  [ -f "$STATE/runtime.env" ] || die "运行环境记录缺失；请用同一一键部署包重新运行 01-deploy.sh。"
  # shellcheck disable=SC1091
  . "$STATE/runtime.env"
  local need
  for need in RT_JDK RT_JAVA_HOME RT_MYSQL; do
    eval "local v=\${$need:-}"
    [ -n "$v" ] || die "运行环境记录缺少 $need；请用同一一键部署包重新运行 01-deploy.sh。"
  done
}

# =============================================================================
# 锁
# =============================================================================
acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # 已有锁：检查持有者是否还活着
    local lpid=""
    [ -f "$LOCK_DIR/pid" ] && lpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
      die "无法获取操作锁（可能有部署/启停操作正在运行）。"
    fi
    # 陈旧锁：持有者已不在
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" || die "无法获取操作锁（目录不可写）。"
  fi
  printf '%s' "$$" > "$LOCK_DIR/pid"
  LOCK_ACQUIRED=1
}
release_lock() { [ "$LOCK_ACQUIRED" = "1" ] && rm -rf "$LOCK_DIR" 2>/dev/null || true; }

# =============================================================================
# 主流程
# =============================================================================
cleanup() {
  local rc=$?
  if [ "$DEPLOY_ACTIVE" = "1" ] && [ "$rc" != "0" ]; then
    DEPLOY_PHASE="部署失败（$CURRENT_STEP）"
    deploy_line "部署失败（见操作日志）" "error"
    write_deploy_status "failed" "部署在步骤「$CURRENT_STEP」失败"
  fi
  rm -f "$CLIENT_FILE" 2>/dev/null || true
  if [ -f "$STATE/mysql-secured" ]; then rm -f "$INIT_FILE" 2>/dev/null || true; fi
  [ -n "$DEPLOY_LINES_FILE" ] && rm -f "$DEPLOY_LINES_FILE" 2>/dev/null || true
  release_lock
}
trap 'cleanup' EXIT
trap 'die "收到中断信号"' INT TERM

main() {
  step "检查系统和安装目录"
  # 安装目录基本校验
  case "$ROOT" in *[\']* ) die "安装路径不能包含单引号。" ;; esac
  if [ "$ACTION" != "deploy" ] && [ ! -f "$STATE/runtime.env" ]; then
    die "未找到安装。请先在同一账号下运行 01-deploy.sh。"
  fi
  if [ "$ACTION" = "deploy" ] && [ -d "$ROOT" ] && [ ! -f "$STATE/owner.json" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
    die "安装目录非空且不属于本安装器；请选择一个空目录。"
  fi
  mkdir -p "$ROOT" "$STATE" "$TOOLS" "$LOGS" "$MYSQL_DATA" "$FILES_DIR" "$DATA/files-private"
  chmod 700 "$STATE"

  # 磁盘空间（首次部署至少 4GB：工具链 + 产物 + 数据库余量）
  if [ "$ACTION" = "deploy" ]; then
    local avail_kb; avail_kb="$(df -Pk "$ROOT" | awk 'NR==2{print $4}')"
    if [ "${avail_kb:-0}" -lt 4194304 ]; then die "首次部署至少需要 4GB 可用磁盘空间。"; fi
  fi

  step "检查安装目录权限和操作锁"
  acquire_lock
  local owner="$STATE/owner.json"
  if [ -f "$owner" ]; then
    local saved_root; saved_root="$(json_get "$owner" root)"
    [ "$saved_root" = "$ROOT" ] || die "请使用原安装路径；本安装不可移动。"
  else
    printf '{"uid":"%s","root":"%s","kind":"MyHome-%s"}\n' "$(id -u)" "$(json_escape "$ROOT")" "$OS_KERNEL" > "$owner"
  fi

  step "创建本次操作日志"
  local log_path="$LOGS/$ACTION.log"
  [ -f "$log_path" ] && mv "$log_path" "$log_path.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  : > "$log_path"; RUN_LOG="$log_path"
  info "Action: $ACTION | Platform: $PLATFORM | Data/install directory: $ROOT | $(date +%Y-%m-%dT%H:%M:%S)"

  # 读取 app/update 段（jar 名、dist 目录名、Release 仓库等），供各 action 使用。
  load_app_manifest

  [ "$ACTION" = "update" ] && init_deploy_status

  step "检查产物直跑安装身份（不接管旧版源码/离线安装）"
  if [ "$ACTION" = "deploy" ]; then assert_artifact_install; else assert_artifact_install require; fi

  # 清单校验（deploy/update）
  local pkg="$SCRIPT_DIR/packages.json"
  if [ "$ACTION" = "deploy" ] || [ "$ACTION" = "update" ]; then
    step "读取格式 4 的一键部署包清单"
    [ -f "$pkg" ] || die "缺少 packages.json；请重新完整拷贝一键部署包。"
    local fv off rm pf
    fv="$(json_get "$pkg" formatVersion)"; off="$(json_get "$pkg" offline)"; rm="$(json_get "$pkg" runMode)"; pf="$(json_get "$pkg" platform)"
    if [ "$fv" != "4" ] || [ "$off" != "false" ] || [ "$rm" != "artifact" ] || [ "$pf" != "$PLATFORM" ]; then
      die "仅支持 formatVersion=4、offline=false、runMode=artifact、platform=$PLATFORM 的一键部署包；请重新完整拷包。"
    fi
    if [ "$ACTION" = "update" ] && [ -z "$UPDATE_REPO" ]; then
      die "清单缺少 update.repo，无法定位 GitHub Release；请重新完整拷贝一键部署包。"
    fi
  fi

  step "加载加密凭据"
  load_secrets

  if [ "$ACTION" = "deploy" ]; then
    step "解压并校验工具链（JDK / MySQL）"
    RT_JDK="$(install_tarball jdk jdk)"
    local jdk_home; jdk_home="$(json_get "$pkg" jdk.home)"
    if [ -n "$jdk_home" ]; then RT_JAVA_HOME="$RT_JDK/$jdk_home"; else RT_JAVA_HOME="$RT_JDK"; fi
    RT_MYSQL="$(install_tarball mysql mysql)"
    # 探针复核
    [ -x "$RT_JAVA_HOME/bin/java" ] || die "JDK 安装不完整（$RT_JAVA_HOME/bin/java）。"
    [ -x "$RT_JAVA_HOME/bin/jar" ] || die "JDK 安装不完整（缺 $RT_JAVA_HOME/bin/jar），无法解包应用产物。"
    [ -x "$RT_MYSQL/bin/mysqld" ] || die "MySQL 安装不完整（$RT_MYSQL/bin/mysqld）。"
    step "保存运行环境记录"
    write_runtime_env
    # 解包随包携带的应用产物
    stop_owned backend
    install_app
    write_installed "$APP_VERSION" "$APP_SERVER_COMMIT" "$APP_WEB_COMMIT" "$(now_iso)" ""
  else
    step "读取已有运行环境记录"
    load_runtime_env
    [ -f "$APP_DIR/$APP_JAR_NAME" ] && [ -f "$APP_VERSION_FILE" ] \
      || die "已部署的应用产物不完整（$APP_DIR）；请运行 01-deploy.sh 重新解包，不要删除 data/ 或 state/。"
    read_app_meta
    if [ "$ACTION" = "update" ]; then
      # 先停后端再下载-校验-替换（jar 文件被运行中的 JVM 占用；替换后由主流程尾部重启）。
      stop_owned backend
      if run_update; then
        info "已替换到新版本：$APP_VERSION"
      else
        info "已是最新版本：$APP_VERSION（未替换产物）"
      fi
    else
      stop_owned backend
    fi
  fi

  if [ "$ACTION" = "stop" ]; then
    stop_database
    info "Stopped. Data, photos and encryption keys are retained."
  else
    ensure_database
    step "启动后端并从产物执行数据库迁移（Flyway）" "$LOGS/server.log" "$LOGS/backend.err.log" "$LOGS/backend.out.log"
    start_backend_logged
    if [ "$(sql "SELECT COUNT(*) FROM family_home.flyway_schema_history WHERE version='103' AND success=1;")" != "1" ]; then
      die "迁移 V103 未成功应用；部署未完成。请查看 logs/server.log。"
    fi
    if [ "$DEPLOY_ACTIVE" = "1" ]; then
      deploy_line "部署完成：后端已重启并通过健康检查（版本 $APP_VERSION）"
      write_deploy_status "done"
      DEPLOY_ACTIVE=0
    fi
    step "整理历史日志和访问入口"
    find "$LOGS" -type f -name '*.log.*' -mtime +7 -delete 2>/dev/null || true
    info "Ready. Open these addresses ON THIS machine:"
    printf '  C-end: http://localhost:%s/\n' "$BACKEND_PORT"
    printf '  Admin: http://localhost:%s/admin/\n' "$BACKEND_PORT"
    printf '  Running version: %s\n' "$APP_VERSION"
    printf '  Fresh database: select 大宝 (administrator) or 小宝; initial password: 123456.\n'
    printf '  Change both passwords in Admin > Personal profile before saving real data.\n'
    printf '  Existing account passwords are NEVER reset by this script.\n'
    printf '  Logs: %s\n' "$LOGS"
    printf '  Restart after reboot: 02-start.sh. Deploy latest release: 04-update.sh. Shut down: 03-stop.sh.\n'
    printf '  No automatic boot task, firewall rule, LAN exposure or sleep-setting changes were made.\n'
    # 尝试打开浏览器（失败不影响部署）
    if [ "$OS_KERNEL" = "Darwin" ]; then open "http://localhost:$BACKEND_PORT/" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "http://localhost:$BACKEND_PORT/" >/dev/null 2>&1 || true; fi
  fi
}

main "$@"
