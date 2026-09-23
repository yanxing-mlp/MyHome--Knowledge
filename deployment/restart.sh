#!/bin/bash
###############################################################################
# MyHome 系统重启脚本（拉取最新代码 + 重新构建 + 启动）
# 
# 用途：在已有部署的基础上，拉取最新代码、重新构建并重启服务
# 前置条件：已完成首次部署（开发环境已安装）
# 
# 使用方法：
#   bash restart.sh                    # 完整重启（后端 + 前后端）
#   bash restart.sh --backend-only     # 只重启后端
#   bash restart.sh --frontend-only    # 只重启前端
#   bash restart.sh --skip-pull        # 跳过 git pull（本地调试用）
#   bash restart.sh --skip-build       # 跳过构建（仅重启）
# 
# 脚本会自动：
#   1. 停止正在运行的服务
#   2. 拉取最新代码（可选）
#   3. 重新构建（可选）
#   4. 启动服务
#   5. 等待服务就绪
###############################################################################

set -euo pipefail

# ===== 颜色输出 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ===== 参数解析 =====
MODE="full"           # full | backend-only | frontend-only
SKIP_PULL=false       # 是否跳过 git pull
SKIP_BUILD=false      # 是否跳过构建

for arg in "$@"; do
    case $arg in
        --backend-only)
            MODE="backend-only"
            shift
            ;;
        --frontend-only)
            MODE="frontend-only"
            shift
            ;;
        --skip-pull)
            SKIP_PULL=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        *)
            ;;
    esac
done

# ===== 项目根目录 =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVER_DIR="$PROJECT_ROOT/family-home-server"
WEB_DIR="$PROJECT_ROOT/family-home-web"

# ===== 检查是否在项目根目录 =====
if [ ! -d "$SERVER_DIR" ] || [ ! -d "$WEB_DIR" ]; then
    error "请在 MyHome 项目根目录下运行此脚本（当前目录缺少 family-home-server 或 family-home-web）"
fi

info "=========================================="
info "  MyHome 系统重启脚本"
info "  模式: $MODE"
info "  跳过拉取: $SKIP_PULL"
info "  跳过构建: $SKIP_BUILD"
info "  项目根目录: $PROJECT_ROOT"
info "=========================================="

###############################################################################
# Step 1: 停止正在运行的服务
###############################################################################
info "[1/6] 停止正在运行的服务..."

# 停止后端
if [ -f /tmp/family-home-backend.pid ]; then
    BACKEND_PID=$(cat /tmp/family-home-backend.pid)
    if ps -p "$BACKEND_PID" > /dev/null 2>&1; then
        info "停止后端服务（PID: $BACKEND_PID）..."
        kill "$BACKEND_PID"
        # 等待进程完全退出
        for i in {1..10}; do
            if ! ps -p "$BACKEND_PID" > /dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        # 如果还在运行，强制杀掉
        if ps -p "$BACKEND_PID" > /dev/null 2>&1; then
            warn "后端未正常退出，强制终止..."
            kill -9 "$BACKEND_PID"
        fi
        success "后端服务已停止"
    else
        warn "后端进程（PID: $BACKEND_PID）不存在，跳过停止"
    fi
    rm -f /tmp/family-home-backend.pid
else
    warn "未找到后端 PID 文件，尝试通过端口查找进程..."
    BACKEND_PIDS=$(lsof -ti:8080 2>/dev/null || true)
    if [ -n "$BACKEND_PIDS" ]; then
        echo "$BACKEND_PIDS" | xargs kill -9
        success "已强制停止占用 8080 端口的进程"
    else
        warn "未发现运行中的后端服务"
    fi
fi

# 停止 B 端
if [ -f /tmp/family-home-admin.pid ]; then
    ADMIN_PID=$(cat /tmp/family-home-admin.pid)
    if ps -p "$ADMIN_PID" > /dev/null 2>&1; then
        info "停止 B 端管理后台（PID: $ADMIN_PID）..."
        kill "$ADMIN_PID"
        sleep 2
        if ps -p "$ADMIN_PID" > /dev/null 2>&1; then
            kill -9 "$ADMIN_PID"
        fi
        success "B 端已停止"
    else
        warn "B 端进程（PID: $ADMIN_PID）不存在，跳过停止"
    fi
    rm -f /tmp/family-home-admin.pid
else
    warn "未找到 B 端 PID 文件"
    # 尝试通过端口查找
    ADMIN_PIDS=$(lsof -ti:5173 2>/dev/null || true)
    if [ -n "$ADMIN_PIDS" ]; then
        echo "$ADMIN_PIDS" | xargs kill -9
        success "已强制停止占用 5173 端口的进程"
    fi
fi

# 停止 C 端
if [ -f /tmp/family-home-h5.pid ]; then
    H5_PID=$(cat /tmp/family-home-h5.pid)
    if ps -p "$H5_PID" > /dev/null 2>&1; then
        info "停止 C 端 H5（PID: $H5_PID）..."
        kill "$H5_PID"
        sleep 2
        if ps -p "$H5_PID" > /dev/null 2>&1; then
            kill -9 "$H5_PID"
        fi
        success "C 端已停止"
    else
        warn "C 端进程（PID: $H5_PID）不存在，跳过停止"
    fi
    rm -f /tmp/family-home-h5.pid
else
    warn "未找到 C 端 PID 文件"
    # 尝试通过端口查找
    H5_PIDS=$(lsof -ti:5174 2>/dev/null || true)
    if [ -n "$H5_PIDS" ]; then
        echo "$H5_PIDS" | xargs kill -9
        success "已强制停止占用 5174 端口的进程"
    fi
fi

# 清理旧日志（保留最近 7 天的）
info "清理旧日志文件..."
find /tmp -name "family-home-*.log.*" -mtime +7 -delete 2>/dev/null || true
# 轮转当前日志
for log_file in /tmp/family-home-backend.log /tmp/family-home-admin.log /tmp/family-home-h5.log; do
    if [ -f "$log_file" ]; then
        mv "$log_file" "${log_file}.$(date +%Y%m%d%H%M%S)"
    fi
done
success "日志已轮转"

###############################################################################
# Step 2: 拉取最新代码
###############################################################################
if [ "$SKIP_PULL" = false ]; then
    info "[2/6] 拉取最新代码..."
    
    # 拉取后端
    cd "$SERVER_DIR"
    if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        info "拉取后端代码..."
        git fetch origin main
        LOCAL_COMMIT=$(git rev-parse HEAD)
        REMOTE_COMMIT=$(git rev-parse origin/main)
        
        if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
            success "后端代码已是最新"
        else
            info "检测到新提交，正在更新..."
            git pull origin main
            success "后端代码已更新到 $(git rev-parse --short HEAD)"
        fi
    else
        warn "后端目录不是 git 仓库，跳过拉取"
    fi
    
    # 拉取前端
    cd "$WEB_DIR"
    if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        info "拉取前端代码..."
        git fetch origin main
        LOCAL_COMMIT=$(git rev-parse HEAD)
        REMOTE_COMMIT=$(git rev-parse origin/main)
        
        if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
            success "前端代码已是最新"
        else
            info "检测到新提交，正在更新..."
            git pull origin main
            success "前端代码已更新到 $(git rev-parse --short HEAD)"
        fi
    else
        warn "前端目录不是 git 仓库，跳过拉取"
    fi
else
    warn "跳过代码拉取（--skip-pull）"
fi

###############################################################################
# Step 3: 安装依赖（前端）
###############################################################################
if [ "$MODE" = "full" ] || [ "$MODE" = "frontend-only" ]; then
    info "[3/6] 检查前端依赖..."
    
    cd "$WEB_DIR"
    
    # 检查 node_modules 是否存在
    if [ ! -d "node_modules" ] || [ ! -d "packages/admin/node_modules" ]; then
        warn "前端依赖未安装，正在执行 pnpm install..."
        pnpm install
        success "前端依赖安装完成"
    else
        # 检查 package.json 是否有变化
        if git diff HEAD~1 --name-only 2>/dev/null | grep -q "package.json\|pnpm-lock.yaml"; then
            info "检测到依赖变更，正在更新..."
            pnpm install
            success "前端依赖更新完成"
        else
            success "前端依赖已是最新"
        fi
    fi
fi

###############################################################################
# Step 4: 构建后端
###############################################################################
if [ "$MODE" = "full" ] || [ "$MODE" = "backend-only" ]; then
    if [ "$SKIP_BUILD" = false ]; then
        info "[4/6] 构建后端..."
        
        cd "$SERVER_DIR"
        
        # 清理旧构建产物
        info "清理旧构建产物..."
        mvn clean -q
        
        # 编译打包
        info "执行 Maven 构建（这可能需要几分钟）..."
        mvn package -DskipTests -q
        success "后端构建完成"
        
        # 显示构建产物信息
        JAR_FILE=$(ls -t fh-boot/target/fh-boot-*.jar 2>/dev/null | head -1)
        if [ -n "$JAR_FILE" ]; then
            JAR_SIZE=$(du -h "$JAR_FILE" | cut -f1)
            success "构建产物: $JAR_FILE ($JAR_SIZE)"
        fi
    else
        warn "跳过构建（--skip-build）"
    fi
fi

###############################################################################
# Step 5: 启动后端
###############################################################################
if [ "$MODE" = "full" ] || [ "$MODE" = "backend-only" ]; then
    info "[5/6] 启动后端服务..."
    
    cd "$SERVER_DIR"
    
    # 确保文件存储目录存在
    STORAGE_DIR="/data/family-home/files"
    if [ ! -d "$STORAGE_DIR" ]; then
        sudo mkdir -p "$STORAGE_DIR"
        sudo chmod 777 "$STORAGE_DIR"
        success "创建文件存储目录: $STORAGE_DIR"
    fi
    
    # 启动后端（后台运行）
    info "启动后端服务（后台运行）..."
    nohup java -jar fh-boot/target/fh-boot-1.0.0-SNAPSHOT.jar \
        --spring.profiles.active=dev \
        > /tmp/family-home-backend.log 2>&1 &
    
    BACKEND_PID=$!
    echo "$BACKEND_PID" > /tmp/family-home-backend.pid
    success "后端已启动（PID: $BACKEND_PID，日志: /tmp/family-home-backend.log）"
    
    # 等待后端启动
    info "等待后端服务就绪..."
    for i in {1..60}; do
        if curl -s http://localhost:8080/health > /dev/null 2>&1; then
            success "后端服务已就绪: http://localhost:8080/health"
            break
        fi
        if [ $i -eq 60 ]; then
            error "后端启动超时，请检查日志: tail -f /tmp/family-home-backend.log"
        fi
        sleep 2
        echo -n "."
    done
    echo ""
fi

###############################################################################
# Step 6: 启动前端
###############################################################################
if [ "$MODE" = "full" ] || [ "$MODE" = "frontend-only" ]; then
    info "[6/6] 启动前端服务..."
    
    cd "$WEB_DIR"
    
    # 启动 B 端管理后台
    info "启动 B 端管理后台（后台运行）..."
    nohup pnpm dev:admin > /tmp/family-home-admin.log 2>&1 &
    ADMIN_PID=$!
    echo "$ADMIN_PID" > /tmp/family-home-admin.pid
    success "B 端已启动（PID: $ADMIN_PID，日志: /tmp/family-home-admin.log）"
    
    # 启动 C 端 H5
    info "启动 C 端 H5（后台运行）..."
    nohup pnpm dev:h5 > /tmp/family-home-h5.log 2>&1 &
    H5_PID=$!
    echo "$H5_PID" > /tmp/family-home-h5.pid
    success "C 端已启动（PID: $H5_PID，日志: /tmp/family-home-h5.log）"
    
    # 等待前端启动
    info "等待前端服务就绪..."
    sleep 10
    
    success "B 端管理后台: http://localhost:5173/admin/"
    success "C 端 H5: http://localhost:5174/"
fi

###############################################################################
# 完成
###############################################################################
info "=========================================="
success "MyHome 系统重启完成！"
info "=========================================="
echo ""
info "访问地址："
if [ "$MODE" = "full" ] || [ "$MODE" = "backend-only" ]; then
    echo "  - 后端健康检查: http://localhost:8080/health"
fi
if [ "$MODE" = "full" ] || [ "$MODE" = "frontend-only" ]; then
    echo "  - B 端管理后台: http://localhost:5173/admin/"
    echo "  - C 端 H5: http://localhost:5174/"
fi
echo ""
info "日志位置："
if [ "$MODE" = "full" ] || [ "$MODE" = "backend-only" ]; then
    echo "  - 后端: /tmp/family-home-backend.log"
fi
if [ "$MODE" = "full" ] || [ "$MODE" = "frontend-only" ]; then
    echo "  - B 端: /tmp/family-home-admin.log"
    echo "  - C 端: /tmp/family-home-h5.log"
fi
echo ""
info "查看实时日志："
if [ "$MODE" = "full" ] || [ "$MODE" = "backend-only" ]; then
    echo "  tail -f /tmp/family-home-backend.log"
fi
if [ "$MODE" = "full" ] || [ "$MODE" = "frontend-only" ]; then
    echo "  tail -f /tmp/family-home-admin.log"
    echo "  tail -f /tmp/family-home-h5.log"
fi
echo ""
info "代码版本："
cd "$SERVER_DIR"
echo "  - 后端: $(git rev-parse --short HEAD) ($(git log -1 --format='%ci'))"
cd "$WEB_DIR"
echo "  - 前端: $(git rev-parse --short HEAD) ($(git log -1 --format='%ci'))"
echo ""
success "祝使用愉快！🎉"
