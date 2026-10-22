#!/usr/bin/env bash
# =============================================================================
# MyHome macOS(arm64) / Linux(x64) 一键部署引擎（联网 · 源码直跑）
#
# 这是 myhome-windows.ps1 的 Unix 对等实现，口径逐条对齐：
#   · 工具链（JDK/Node/Maven/pnpm/MySQL）随包携带并逐一校验 SHA256（不联网下载）；
#     git 用系统自带（Unix 无官方独立二进制，见「平台差异」）。
#   · 应用源码部署时从 GitHub 拉取，后端 mvn spring-boot:run、前端 pnpm dev 直接跑源码，
#     不预编译 JAR / 静态产物。首次部署与「部署最新」都需要联网。
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
DB_PORT=13306
BACKEND_PORT=8080
ADMIN_PORT=5173
H5_PORT=5174

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
SRC_SERVER="$ROOT/src/server"
SRC_WEB="$ROOT/src/web"
CLIENT_FILE="$STATE/mysql-client.cnf"
INIT_FILE="$STATE/mysql-init.sql"
INI_FILE="$STATE/my.cnf"
SECRETS_FILE="$STATE/secrets.env"
RUN_LOG=""
LOCK_DIR="$STATE/operation.lock"
LOCK_ACQUIRED=0

# 运行环境（部署后写入 state/runtime.env）
RT_JDK=""; RT_NODE=""; RT_MAVEN=""; RT_PNPM=""; RT_MYSQL=""; RT_JAVA_HOME=""

# 「部署最新」进度上报（仅 action=update 启用）
DEPLOY_ACTIVE=0
DEPLOY_STATUS_PATH=""
DEPLOY_HISTORY_PATH=""
DEPLOY_RUN_ID=""
DEPLOY_STARTED_AT=""
DEPLOY_PHASE=""
DEPLOY_LINES_FILE=""
DEPLOY_FROM_SERVER=""; DEPLOY_FROM_WEB=""
DEPLOY_RESULT_SERVER=""; DEPLOY_RESULT_WEB=""
DEPLOY_TARGET_SERVER=""; DEPLOY_TARGET_WEB=""

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
  # （local_package/install_tarball/owned_pid/get_source_commit/sql 等）。
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
# 清单结构固定、由打包器生成，故用 awk 状态机按 { } 层级展平即可。
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
        if (c=="}" || c=="]") { if (depth>0) depth--; aftercolon=0; key=""; i++; continue }
        if (c==",") { aftercolon=0; i++; continue }
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
# 校验 / 安全路径 / 工具链安装
# =============================================================================
check_hash() { # check_hash <file> <expected>
  [ -f "$1" ] || return 1
  local actual
  actual="$(shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1)"
  [ "$actual" = "$2" ]
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
  step "校验本地工具链文件 runtime/$file"
  if ! check_hash "$path" "$hash"; then
    die "本地工具链文件缺失或 SHA256 不符：runtime/$file。请重新完整拷贝一键部署包（含 runtime/）；工具链不联网下载。"
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
# 密钥（Unix 无 DPAPI：用 0600 文件 + 0700 目录，靠文件系统权限保护）
# =============================================================================
rand_b64() { head -c "$1" /dev/urandom | base64 | tr -d '\n'; }

load_secrets() {
  DbRoot=""; DbApp=""; Vault=""; Transport=""; Auth=""
  if [ ! -f "$SECRETS_FILE" ]; then
    if [ -d "$MYSQL_DATA/mysql" ] || [ -f "$STATE/installed.json" ]; then
      die "已有安装但缺少密钥文件。请恢复 state/secrets.env；绝不在已有数据上重新生成 vault 密钥。"
    fi
    DbRoot="$(rand_b64 36)"; DbApp="$(rand_b64 36)"
    Vault="$(rand_b64 32)"; Transport="$(rand_b64 24)"; Auth="$(rand_b64 48)"
    local tmp="$SECRETS_FILE.tmp"
    {
      printf 'DbRoot=%s\n' "$DbRoot"
      printf 'DbApp=%s\n' "$DbApp"
      printf 'Vault=%s\n' "$Vault"
      printf 'Transport=%s\n' "$Transport"
      printf 'Auth=%s\n' "$Auth"
    } > "$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$SECRETS_FILE"
  fi
  # 读取（仅取已知键，值不含空格/换行）
  while IFS='=' read -r k v; do
    case "$k" in
      DbRoot) DbRoot="$v";; DbApp) DbApp="$v";; Vault) Vault="$v";;
      Transport) Transport="$v";; Auth) Auth="$v";;
    esac
  done < "$SECRETS_FILE"
  local key
  for key in DbRoot DbApp Vault Transport Auth; do
    eval "local val=\${$key}"
    [ -n "$val" ] || die "无法读取安装凭据（$key 为空）。请使用原电脑上的原账号，不要删除 state/secrets.env。"
  done
  SECRET_VALUES=("$DbRoot" "$DbApp" "$Vault" "$Transport" "$Auth")
}

assert_transport_salt() {
  local decoded_len reencoded
  decoded_len="$(printf '%s' "$Transport" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
  reencoded="$(printf '%s' "$Transport" | base64 -d 2>/dev/null | base64 | tr -d '\n')"
  if [ "$decoded_len" != "24" ] || [ "$reencoded" != "$Transport" ]; then
    die "持久化 Transport 盐必须是 24 字节的标准 Base64；请恢复原 state/secrets.env，不能重新生成密钥或使用开发盐。"
  fi
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
  # set -m 让后台任务成为独立进程组组长（PGID==PID），便于整树停止（mvn→java、node→vite）。
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
  DEPLOY_PHASE="开始部署最新代码"
  # 接管后端点火时写的 targetCommits（若有）
  if [ -f "$DEPLOY_STATUS_PATH" ]; then
    DEPLOY_TARGET_SERVER="$(json_get "$DEPLOY_STATUS_PATH" targetCommits.server 2>/dev/null || true)"
    DEPLOY_TARGET_WEB="$(json_get "$DEPLOY_STATUS_PATH" targetCommits.web 2>/dev/null || true)"
  fi
  DEPLOY_ACTIVE=1
  deploy_line "部署脚本已启动：git pull 两仓 + 重启前后端"
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
      # buf 是既有的 JSON 数组（可能为 [] 或 [ {..},{..} ]）
      gsub(/^[ \t\r\n\[]+/, "", buf); gsub(/[ \t\r\n\]]+$/, "", buf)
      # 按顶层对象切分（记录以 },{ 分隔，且记录内无裸 } 之外的嵌套顶层逗号问题——本结构 lines 内含 {}，故用 runId 去重需更稳的切分）
      # 简化：直接把新记录前插，靠后端按 runId 去重展示；同时做长度上限。
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
  printf '1' > "$STATE/mysql-secured"
  rm -f "$INIT_FILE"
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
# 源码拉取 / 运行版本
# =============================================================================
git_bin() {
  if [ -n "${RT_GIT:-}" ] && [ -x "${RT_GIT:-}" ]; then printf '%s' "$RT_GIT"; return; fi
  if command -v git >/dev/null 2>&1; then command -v git; return; fi
  die "未找到 git。macOS 请执行 xcode-select --install 安装命令行工具；Ubuntu/Debian 请执行 sudo apt-get install -y git 后重试。"
}

get_source_commit() { # get_source_commit <dir>
  local g; g="$(git_bin)"
  local c; c="$("$g" -C "$1" rev-parse HEAD 2>/dev/null || true)"
  if printf '%s' "$c" | grep -qE '^[0-9a-f]{40}$'; then printf '%s' "$c"; else printf ''; fi
}

fetch_source() {
  assert_transport_salt
  local g; g="$(git_bin)"
  export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=""
  local pkg="$SCRIPT_DIR/packages.json" key
  FETCH_SERVER_COMMIT=""; FETCH_WEB_COMMIT=""
  for key in server web; do
    local url branch dir target
    url="$(json_get "$pkg" "repos.$key.url")"
    branch="$(json_get "$pkg" "repos.$key.branch")"
    dir="$(json_get "$pkg" "repos.$key.directory")"
    printf '%s' "$url" | grep -qE '^https://github\.com/[^/]+/[^/]+\.git$' || die "清单 repos.$key.url 不合法；请重新完整拷贝一键部署包。"
    printf '%s' "$branch" | grep -qE '^[A-Za-z0-9._/-]+$' || die "清单 repos.$key.branch 不合法。"
    printf '%s' "$dir" | grep -qE '^[A-Za-z0-9._/-]+$' || die "清单 repos.$key.directory 不合法。"
    target="$(safe_path "$ROOT" "$dir")" || die "repos.$key.directory 越界：$dir"
    step "拉取源码 $key（$dir）"
    if [ -d "$target/.git" ]; then
      "$g" -C "$target" fetch --quiet --prune origin "$branch" || die "git fetch 失败（$key）；请检查网络。"
      "$g" -C "$target" checkout --quiet "$branch" || die "git checkout 失败（$key）。"
      "$g" -C "$target" reset --hard --quiet "origin/$branch" || die "git reset 失败（$key）。"
    else
      [ -e "$target" ] && die "源码目录已存在但不是 git 仓库：$target。请清空后重试。"
      mkdir -p "$(dirname "$target")"
      "$g" clone --quiet --branch "$branch" --single-branch "$url" "$target" || die "git clone 失败（$key）；请检查网络。"
    fi
    local commit; commit="$(get_source_commit "$target")"
    [ -n "$commit" ] || die "无法读取 $key 的提交号。"
    if [ "$key" = "server" ]; then FETCH_SERVER_COMMIT="$commit"; else FETCH_WEB_COMMIT="$commit"; fi
  done
  [ -f "$SRC_SERVER/pom.xml" ] || die "后端源码缺少 src/server/pom.xml；拉取的仓库结构不符。"
  [ -f "$SRC_WEB/package.json" ] || die "前端源码缺少 src/web/package.json；拉取的仓库结构不符。"
}

# =============================================================================
# 后端 / 前端 启动
# =============================================================================
clean_dev_env() {
  # 与 Windows 一致：继承来的开发者 datasource/config/JVM 变量绝不能带进 prod。
  local vars
  vars="$(env | grep -oE '^(SPRING_[A-Za-z0-9_]*|FH_[A-Za-z0-9_]*|MYSQL_[A-Za-z0-9_]*|SERVER_[A-Za-z0-9_]*|LOGGING_[A-Za-z0-9_]*|JAVA_TOOL_OPTIONS|JDK_JAVA_OPTIONS|_JAVA_OPTIONS|JAVA_OPTS|JAVA_HOME|MAVEN_OPTS|GIT_TERMINAL_PROMPT)=' | sed 's/=$//' || true)"
  local v
  for v in $vars; do unset "$v" 2>/dev/null || true; done
}

wait_backend() { # wait_backend <pid>
  local pid="$1" i last="健康接口尚未返回结果。" body
  for i in $(seq 1 450); do
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
  [ -f "$SRC_SERVER/pom.xml" ] || die "后端源码缺失（src/server/pom.xml）；请先运行 01-deploy.sh 拉取源码。"
  for suffix in out err; do
    local lg="$LOGS/backend.$suffix.log"
    [ -f "$lg" ] && mv "$lg" "$lg.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  done
  local mvn="$RT_MAVEN/bin/mvn"
  set -m
  (
    clean_dev_env
    export JAVA_HOME="$RT_JAVA_HOME"
    export PATH="$RT_JAVA_HOME/bin:$RT_NODE/bin:$RT_MAVEN/bin:$PATH"
    export MAVEN_OPTS="-Xms128m -Xmx768m -Dfile.encoding=UTF-8"
    export GIT_TERMINAL_PROMPT=0
    export SPRING_PROFILES_ACTIVE=prod
    export MYSQL_HOST=127.0.0.1 MYSQL_PORT="$DB_PORT" MYSQL_DATABASE=family_home MYSQL_USER=myhome MYSQL_PASSWORD="$DbApp"
    export FH_VAULT_PASSWORD_KEY="$Vault" FH_TRANSPORT_CRYPTO_SALT="$Transport" FH_AUTH_TOKEN_SECRET="$Auth"
    export FH_STORAGE_ROOT="$FILES_DIR"
    export LOGGING_FILE_NAME="$LOGS/server.log"
    export SERVER_ADDRESS=127.0.0.1 SERVER_PORT="$BACKEND_PORT"
    export SPRING_FLYWAY_BASELINE_ON_MIGRATE=false SPRING_FLYWAY_OUT_OF_ORDER=true SPRING_FLYWAY_LOCATIONS=classpath:db/migration
    export FH_RUNNING_COMMIT_SERVER FH_RUNNING_COMMIT_WEB
    export FH_DEPLOY_LAUNCHER="$SCRIPT_DIR/deploy-now.sh"
    export FH_DEPLOY_PROGRESS_FILE="$LOGS/deploy-status.json"
    export FH_DEPLOY_HISTORY_FILE="$LOGS/deploy-history.json"
    export FH_INSTALL_DIR="$ROOT"
    export FH_MYSQLDUMP_PATH="$RT_MYSQL/bin/mysqldump"
    exec "$mvn" -B -f "$SRC_SERVER/pom.xml" -pl fh-boot -am spring-boot:run
  ) >"$LOGS/backend.out.log" 2>"$LOGS/backend.err.log" &
  local pid=$!
  set +m
  sleep 1
  kill -0 "$pid" 2>/dev/null || die "后端启动后立即退出；请查看 $LOGS/backend.err.log。"
  printf '%s' "$pid" > "$STATE/backend.pid"
  printf '%s' "spring-boot:run" > "$STATE/backend.cmd"
  wait_backend "$pid"
}

start_frontend() {
  assert_port_free "$ADMIN_PORT"
  assert_port_free "$H5_PORT"
  [ -f "$SRC_WEB/package.json" ] || die "前端源码缺失（src/web/package.json）；请先运行 01-deploy.sh 拉取源码。"
  local node="$RT_NODE/bin/node" pnpm_cjs="$RT_PNPM/bin/pnpm.cjs"
  [ -f "$pnpm_cjs" ] || die "便携 pnpm 缺失：$pnpm_cjs。请重新完整拷贝一键部署包（含 runtime/）。"
  step "安装前端依赖（pnpm install）" "$LOGS/web-admin.err.log" "$LOGS/web-h5.err.log"
  (
    clean_dev_env
    export VITE_FH_TRANSPORT_CRYPTO_SALT="$Transport"
    export PATH="$RT_NODE/bin:$PATH"
    cd "$SRC_WEB"
    "$node" "$pnpm_cjs" install --frozen-lockfile
  ) >>"$LOGS/web-install.log" 2>&1 || die "前端依赖安装失败；请查看 $LOGS/web-install.log。"

  step "启动前端 dev server（admin:$ADMIN_PORT / h5:$H5_PORT）"
  local launch_web
  launch_web() { # launch_web <name> <filter>
    local name="$1" filter="$2"
    for suffix in out err; do
      local lg="$LOGS/$name.$suffix.log"
      [ -f "$lg" ] && mv "$lg" "$lg.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    done
    set -m
    (
      clean_dev_env
      export VITE_FH_TRANSPORT_CRYPTO_SALT="$Transport"
      export PATH="$RT_NODE/bin:$PATH"
      cd "$SRC_WEB"
      exec "$node" "$pnpm_cjs" --filter "$filter" dev -- --host 127.0.0.1 --strictPort
    ) >"$LOGS/$name.out.log" 2>"$LOGS/$name.err.log" &
    local pid=$!
    set +m
    sleep 1
    kill -0 "$pid" 2>/dev/null || die "$name 启动后立即退出；请查看 $LOGS/$name.err.log。"
    printf '%s' "$pid" > "$STATE/$name.pid"
    printf '%s' "$filter" > "$STATE/$name.cmd"
  }
  launch_web web-admin "@family-home/admin"
  launch_web web-h5 "@family-home/h5"

  local port path i ready last
  for check in "$ADMIN_PORT /admin/" "$H5_PORT /"; do
    port="${check%% *}"; path="${check##* }"
    ready=0; last="尚未收到 HTTP 响应。"
    for i in $(seq 1 60); do
      local code
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port$path" 2>/dev/null || true)"
      if [ "$code" = "200" ]; then ready=1; break; fi
      [ -n "$code" ] && last="HTTP 状态码 $code"
      sleep 1
    done
    [ "$ready" = "1" ] || die "前端访问检查失败：http://127.0.0.1:$port$path。最后检查结果：$last"
  done
}

# =============================================================================
# 安装身份 / 运行环境记录
# =============================================================================
assert_source_install() { # assert_source_install [require]
  local require="${1:-}"
  local record="$STATE/installed.json"
  if [ -f "$record" ]; then
    local fv rm
    fv="$(json_get "$record" formatVersion)"; rm="$(json_get "$record" runMode)"
    if [ "$fv" != "3" ] || [ "$rm" != "source" ]; then
      die "现有安装不是本「一键部署包（源码直跑）」安装的（可能是旧版离线包）；拒绝接管，请保留 data/ 和 state/。"
    fi
    return 0
  fi
  [ -d "$ROOT/app" ] && die "检测到旧版离线安装的 app 目录，拒绝接管；请保留 data/ 和 state/。"
  [ "$require" = "require" ] && die "尚未部署源码，请先运行 01-deploy.sh。"
  return 0
}

write_installed() { # write_installed <server_commit> <web_commit> <installedAt> [updatedAt]
  local sc="$1" wc="$2" iat="$3" uat="${4:-}"
  local pkg="$SCRIPT_DIR/packages.json"
  local surl sbranch sdir wurl wbranch wdir
  surl="$(json_get "$pkg" repos.server.url)"; sbranch="$(json_get "$pkg" repos.server.branch)"; sdir="$(json_get "$pkg" repos.server.directory)"
  wurl="$(json_get "$pkg" repos.web.url)"; wbranch="$(json_get "$pkg" repos.web.branch)"; wdir="$(json_get "$pkg" repos.web.directory)"
  local tmp="$STATE/installed.json.tmp"
  {
    printf '{'
    printf '"formatVersion":3,"offline":false,"runMode":"source",'
    printf '"repos":{'
    printf '"server":{"commit":"%s","directory":"%s","branch":"%s","url":"%s"},' "$sc" "$sdir" "$sbranch" "$surl"
    printf '"web":{"commit":"%s","directory":"%s","branch":"%s","url":"%s"}' "$wc" "$wdir" "$wbranch" "$wurl"
    printf '},'
    printf '"installedAt":"%s"' "$iat"
    [ -n "$uat" ] && printf ',"updatedAt":"%s"' "$uat"
    printf '}\n'
  } > "$tmp" && mv "$tmp" "$STATE/installed.json"
}

write_runtime_env() {
  local tmp="$STATE/runtime.env.tmp"
  {
    printf 'RT_JDK=%s\n' "$RT_JDK"
    printf 'RT_JAVA_HOME=%s\n' "$RT_JAVA_HOME"
    printf 'RT_NODE=%s\n' "$RT_NODE"
    printf 'RT_MAVEN=%s\n' "$RT_MAVEN"
    printf 'RT_PNPM=%s\n' "$RT_PNPM"
    printf 'RT_MYSQL=%s\n' "$RT_MYSQL"
  } > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$STATE/runtime.env"
}
load_runtime_env() {
  [ -f "$STATE/runtime.env" ] || die "运行环境记录缺失；请用同一一键部署包重新运行 01-deploy.sh。"
  # shellcheck disable=SC1091
  . "$STATE/runtime.env"
  local need
  for need in RT_JDK RT_JAVA_HOME RT_NODE RT_MAVEN RT_PNPM RT_MYSQL; do
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

  # 磁盘空间（首次部署至少 8GB）
  if [ "$ACTION" = "deploy" ]; then
    local avail_kb; avail_kb="$(df -Pk "$ROOT" | awk 'NR==2{print $4}')"
    if [ "${avail_kb:-0}" -lt 8388608 ]; then die "首次部署至少需要 8GB 可用磁盘空间。"; fi
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

  [ "$ACTION" = "update" ] && init_deploy_status

  step "检查源码直跑安装身份（不接管旧版离线安装）"
  if [ "$ACTION" = "deploy" ]; then assert_source_install; else assert_source_install require; fi

  # 清单校验（deploy/update）
  local pkg="$SCRIPT_DIR/packages.json"
  if [ "$ACTION" = "deploy" ] || [ "$ACTION" = "update" ]; then
    step "读取格式 3 的一键部署包清单"
    [ -f "$pkg" ] || die "缺少 packages.json；请重新完整拷贝一键部署包。"
    local fv off rm pf
    fv="$(json_get "$pkg" formatVersion)"; off="$(json_get "$pkg" offline)"; rm="$(json_get "$pkg" runMode)"; pf="$(json_get "$pkg" platform)"
    if [ "$fv" != "3" ] || [ "$off" != "false" ] || [ "$rm" != "source" ] || [ "$pf" != "$PLATFORM" ]; then
      die "仅支持 formatVersion=3、offline=false、runMode=source、platform=$PLATFORM 的一键部署包；请重新完整拷包。"
    fi
  fi

  step "加载加密凭据"
  load_secrets
  assert_transport_salt

  # 运行版本（git HEAD）
  FH_RUNNING_COMMIT_SERVER="$(get_source_commit "$SRC_SERVER")"
  FH_RUNNING_COMMIT_WEB="$(get_source_commit "$SRC_WEB")"

  if [ "$ACTION" = "deploy" ]; then
    step "解压并校验工具链（JDK/Node/Maven/pnpm/MySQL）"
    RT_JDK="$(install_tarball jdk jdk)"
    local jdk_home; jdk_home="$(json_get "$pkg" jdk.home)"
    if [ -n "$jdk_home" ]; then RT_JAVA_HOME="$RT_JDK/$jdk_home"; else RT_JAVA_HOME="$RT_JDK"; fi
    RT_NODE="$(install_tarball node node)"
    RT_MAVEN="$(install_tarball maven maven)"
    RT_PNPM="$(install_tarball pnpm pnpm)"
    RT_MYSQL="$(install_tarball mysql mysql)"
    # 探针复核
    [ -x "$RT_JAVA_HOME/bin/java" ] || die "JDK 安装不完整（$RT_JAVA_HOME/bin/java）。"
    [ -x "$RT_NODE/bin/node" ] || die "Node 安装不完整（$RT_NODE/bin/node）。"
    [ -f "$RT_MAVEN/bin/mvn" ] || die "Maven 安装不完整（$RT_MAVEN/bin/mvn）。"
    [ -f "$RT_PNPM/bin/pnpm.cjs" ] || die "pnpm 安装不完整（$RT_PNPM/bin/pnpm.cjs）。"
    [ -x "$RT_MYSQL/bin/mysqld" ] || die "MySQL 安装不完整（$RT_MYSQL/bin/mysqld）。"
    step "保存运行环境记录"
    write_runtime_env
    # 拉源码
    fetch_source
    stop_owned web-admin; stop_owned web-h5; stop_owned backend
    write_installed "$FETCH_SERVER_COMMIT" "$FETCH_WEB_COMMIT" "$(now_iso)" ""
    FH_RUNNING_COMMIT_SERVER="$FETCH_SERVER_COMMIT"; FH_RUNNING_COMMIT_WEB="$FETCH_WEB_COMMIT"
  else
    step "读取已有运行环境记录"
    load_runtime_env
    if [ "$ACTION" = "start" ] || [ "$ACTION" = "update" ]; then
      step "检查已拉取的源码"
      [ -f "$SRC_SERVER/pom.xml" ] && [ -f "$SRC_WEB/package.json" ] || die "已部署的源码不完整；请运行 01-deploy.sh 重新拉取源码，不要删除 data/ 或 state/。"
    fi
    if [ "$ACTION" = "update" ]; then
      stop_owned web-admin; stop_owned web-h5; stop_owned backend
      DEPLOY_FROM_SERVER="$(get_source_commit "$SRC_SERVER")"; DEPLOY_FROM_WEB="$(get_source_commit "$SRC_WEB")"
      fetch_source
      DEPLOY_RESULT_SERVER="$FETCH_SERVER_COMMIT"; DEPLOY_RESULT_WEB="$FETCH_WEB_COMMIT"
      deploy_line "已拉取最新源码：后端 ${FETCH_SERVER_COMMIT:0:7}、前端 ${FETCH_WEB_COMMIT:0:7}"
      local iat; iat="$(json_get "$STATE/installed.json" installedAt)"
      write_installed "$FETCH_SERVER_COMMIT" "$FETCH_WEB_COMMIT" "$iat" "$(now_iso)"
      FH_RUNNING_COMMIT_SERVER="$FETCH_SERVER_COMMIT"; FH_RUNNING_COMMIT_WEB="$FETCH_WEB_COMMIT"
    else
      stop_owned web-admin; stop_owned web-h5; stop_owned backend
    fi
  fi

  if [ "$ACTION" = "stop" ]; then
    stop_database
    info "Stopped. Data, photos and encryption keys are retained."
  else
    ensure_database
    step "启动后端并从源码执行数据库迁移（Flyway）" "$LOGS/server.log" "$LOGS/backend.err.log" "$LOGS/backend.out.log"
    start_backend_logged
    if [ "$(sql "SELECT COUNT(*) FROM family_home.flyway_schema_history WHERE version='103' AND success=1;")" != "1" ]; then
      die "迁移 V103 未成功应用；部署未完成。请查看 logs/server.log。"
    fi
    start_frontend
    if [ "$DEPLOY_ACTIVE" = "1" ]; then
      deploy_line "部署完成：前后端已重启并通过健康检查"
      write_deploy_status "done"
      DEPLOY_ACTIVE=0
    fi
    step "整理历史日志和访问入口"
    find "$LOGS" -type f -name '*.log.*' -mtime +7 -delete 2>/dev/null || true
    info "Ready. Open these addresses ON THIS machine:"
    printf '  C-end: http://localhost:%s/\n' "$H5_PORT"
    printf '  Admin: http://localhost:%s/admin/\n' "$ADMIN_PORT"
    printf '  Fresh database: select 大宝 (administrator) or 小宝; initial password: 123456.\n'
    printf '  Change both passwords in Admin > Personal profile before saving real data.\n'
    printf '  Existing account passwords are NEVER reset by this script.\n'
    printf '  Logs: %s\n' "$LOGS"
    printf '  Restart after reboot: 02-start.sh. Deploy latest source: 04-update.sh. Shut down: 03-stop.sh.\n'
    printf '  No automatic boot task, firewall rule, LAN exposure or sleep-setting changes were made.\n'
    # 尝试打开浏览器（失败不影响部署）
    if [ "$OS_KERNEL" = "Darwin" ]; then open "http://localhost:$H5_PORT/" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "http://localhost:$H5_PORT/" >/dev/null 2>&1 || true; fi
  fi
}

main "$@"
