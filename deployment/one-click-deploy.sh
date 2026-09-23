#!/bin/bash
###############################################################################
# MyHome 一键部署脚本（macOS / Linux）
# 
# 用途：在全新电脑上从零开始搭建整个 MyHome 系统（无需任何前置条件）
# 前置条件：仅需网络连接（内网需能访问 MySQL 8.0）
# 
# 使用方法：
#   bash one-click-deploy.sh          # 默认 dev 模式，前后端一起启动
#   bash one-click-deploy.sh --backend-only   # 只启动后端
#   bash one-click-deploy.sh --frontend-only  # 只启动前端
# 
# 脚本会自动检测并安装：
#   - Git（版本控制工具）
#   - Homebrew（macOS）或 apt-get/yum（Linux Ubuntu/Debian/CentOS）
#   - JDK 21（OpenJDK，Spring Boot 3.5 必需）
#   - Maven 3.9+（后端构建工具）
#   - Node.js 22+（含 pnpm，前端构建环境）
#   - MySQL 8.0（可选本地安装，也可连接远程数据库）
# 
# 最终效果：
#   - 后端：http://localhost:8080/health
#   - B 端管理后台：http://localhost:5173/admin/
#   - C 端 H5：http://localhost:5174/
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
MODE="full"  # full | backend-only | frontend-only
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
        *)
            ;;
    esac
done

# ===== 项目根目录（自动定位，可在任意位置运行脚本）=====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 脚本在 deployment/ 目录下，向上一级就是知识库根目录
KNOWLEDGE_ROOT="$SCRIPT_DIR/.."

# 代码仓库可能在两个位置：
# 1. 知识库同级目录（首次部署时）
# 2. 知识库目录内的 code/ 子目录（如果用户这样组织）
if [ -d "$KNOWLEDGE_ROOT/../family-home-server" ]; then
    # 场景1：代码在知识库外部的独立目录
    PROJECT_ROOT="$KNOWLEDGE_ROOT/.."
elif [ -d "$KNOWLEDGE_ROOT/code/family-home-server" ]; then
    # 场景2：代码在知识库内部的 code/ 目录
    PROJECT_ROOT="$KNOWLEDGE_ROOT/code"
else
    # 场景3：代码尚未克隆，将在后续步骤中克隆到知识库同级目录
    PROJECT_ROOT="$KNOWLEDGE_ROOT/.."
fi

SERVER_DIR="$PROJECT_ROOT/family-home-server"
WEB_DIR="$PROJECT_ROOT/family-home-web"

info "=========================================="
info "  MyHome 一键部署脚本"
info "  模式: $MODE"
info "  项目根目录: $PROJECT_ROOT"
info "=========================================="

###############################################################################
# Step 1: 检测操作系统与包管理器
###############################################################################
info "[1/11] 检测操作系统与包管理器..."

OS_TYPE="$(uname -s)"
PACKAGE_MANAGER=""

case "$OS_TYPE" in
    Darwin*)
        info "检测到 macOS 系统"
        if command -v brew &> /dev/null; then
            success "Homebrew 已安装: $(brew --version | head -1)"
            PACKAGE_MANAGER="brew"
        else
            warn "Homebrew 未安装，正在安装..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            eval "$(/opt/homebrew/bin/brew shellenv)"
            PACKAGE_MANAGER="brew"
            success "Homebrew 安装完成"
        fi
        ;;
    Linux*)
        info "检测到 Linux 系统"
        if command -v apt-get &> /dev/null; then
            success "apt-get 可用"
            PACKAGE_MANAGER="apt"
        elif command -v yum &> /dev/null; then
            success "yum 可用"
            PACKAGE_MANAGER="yum"
        else
            error "未检测到支持的包管理器（需要 apt-get 或 yum）"
        fi
        ;;
    *)
        error "不支持的操作系统: $OS_TYPE（仅支持 macOS 和 Linux）"
        ;;
esac

###############################################################################
# Step 2: 安装 Git（如果尚未存在）
###############################################################################
info "[2/11] 检查 Git..."

if command -v git &> /dev/null; then
    GIT_VERSION=$(git --version | awk '{print $3}')
    success "Git $GIT_VERSION 已安装"
else
    info "Git 未安装，正在安装..."
    case "$OS_TYPE" in
        Darwin*)
            # macOS：先装 Command Line Tools（如果还没装）
            if ! xcode-select -p > /dev/null 2>&1; then
                warn "Command Line Tools 未安装，请先运行: xcode-select --install"
                info "安装完成后重新运行此脚本"
                exit 1
            fi
            brew install git
            ;;
        Linux*)
            case "$PACKAGE_MANAGER" in
                apt)
                    sudo apt-get update
                    sudo apt-get install -y git
                    ;;
                yum)
                    sudo yum install -y git
                    ;;
                *)
                    error "不支持的包管理器: $PACKAGE_MANAGER"
                    ;;
            esac
            ;;
        *)
            error "不支持的操作系统: $OS_TYPE"
            ;;
    esac
    success "Git 安装完成: $(git --version | awk '{print $3}')"
fi

# 配置 git 用户信息（如果尚未配置）
if [ -z "$(git config --global user.name 2>/dev/null)" ]; then
    warn "Git 用户信息未配置，请设置："
    read -p "请输入你的 Git 用户名: " GIT_USER
    read -p "请输入你的 Git 邮箱: " GIT_EMAIL
    git config --global user.name "$GIT_USER"
    git config --global user.email "$GIT_EMAIL"
    success "Git 用户信息已配置: $GIT_USER <$GIT_EMAIL>"
else
    GIT_USER=$(git config --global user.name)
    GIT_EMAIL=$(git config --global user.email)
    success "Git 用户信息已配置: $GIT_USER <$GIT_EMAIL>"
fi

###############################################################################
# Step 3: 安装 JDK 21
###############################################################################
info "[3/11] 检查 JDK 21..."

if command -v java &> /dev/null; then
    JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
    if [ "$JAVA_VERSION" -ge 21 ]; then
        success "JDK $JAVA_VERSION 已安装"
    else
        warn "当前 JDK 版本为 $JAVA_VERSION，需要 JDK 21+"
        case "$PACKAGE_MANAGER" in
            brew)
                brew install openjdk@21
                ;;
            apt)
                sudo apt-get update
                sudo apt-get install -y openjdk-21-jdk
                ;;
            yum)
                sudo yum install -y java-21-openjdk-devel
                ;;
        esac
        success "JDK 21 安装完成"
    fi
else
    info "JDK 未安装，正在安装 JDK 21..."
    case "$PACKAGE_MANAGER" in
        brew)
            brew install openjdk@21
            ;;
        apt)
            sudo apt-get update
            sudo apt-get install -y openjdk-21-jdk
            ;;
        yum)
            sudo yum install -y java-21-openjdk-devel
            ;;
    esac
    success "JDK 21 安装完成"
fi

# 设置 JAVA_HOME（macOS Homebrew 路径）
if [ "$OS_TYPE" = "Darwin" ]; then
    export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
elif [ "$OS_TYPE" = "Linux" ]; then
    export JAVA_HOME="/usr/lib/jvm/java-21-openjdk"
fi

export PATH="$JAVA_HOME/bin:$PATH"
success "JAVA_HOME=$JAVA_HOME"

###############################################################################
# Step 3: 安装 Maven
###############################################################################
info "[4/11] 检查 Maven..."

if command -v mvn &> /dev/null; then
    MVN_VERSION=$(mvn -version | grep "Apache Maven" | awk '{print $3}')
    success "Maven $MVN_VERSION 已安装"
else
    info "Maven 未安装，正在安装..."
    case "$PACKAGE_MANAGER" in
        brew)
            brew install maven
            ;;
        apt)
            sudo apt-get install -y maven
            ;;
        yum)
            sudo yum install -y maven
            ;;
    esac
    success "Maven 安装完成"
fi

###############################################################################
# Step 4: 安装 Node.js 22+ 与 pnpm
###############################################################################
info "[5/11] 检查 Node.js 22+ 与 pnpm..."

NODE_REQUIRED=22

if command -v node &> /dev/null; then
    NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [ "$NODE_VERSION" -ge "$NODE_REQUIRED" ]; then
        success "Node.js $NODE_VERSION 已安装"
    else
        warn "当前 Node.js 版本为 $NODE_VERSION，需要 $NODE_REQUIRED+"
        case "$PACKAGE_MANAGER" in
            brew)
                brew install node@22
                ;;
            apt)
                curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
                sudo apt-get install -y nodejs
                ;;
            yum)
                curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
                sudo yum install -y nodejs
                ;;
        esac
        success "Node.js 22 安装完成"
    fi
else
    info "Node.js 未安装，正在安装 Node.js 22..."
    case "$PACKAGE_MANAGER" in
        brew)
            brew install node@22
            ;;
        apt)
            curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
            sudo apt-get install -y nodejs
            ;;
        yum)
            curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
            sudo yum install -y nodejs
            ;;
    esac
    success "Node.js 22 安装完成"
fi

# 安装 pnpm
if command -v pnpm &> /dev/null; then
    PNPM_VERSION=$(pnpm -v)
    success "pnpm $PNPM_VERSION 已安装"
else
    info "pnpm 未安装，正在安装..."
    npm install -g pnpm
    success "pnpm 安装完成"
fi

###############################################################################
# Step 5: 安装 MySQL 8.0（可选）
###############################################################################
info "[6/11] 检查 MySQL 8.0..."

MYSQL_INSTALLED=false
if command -v mysql &> /dev/null; then
    MYSQL_VERSION=$(mysql --version | awk '{print $3}' | cut -d'-' -f1)
    MYSQL_MAJOR=$(echo "$MYSQL_VERSION" | cut -d'.' -f1)
    if [ "$MYSQL_MAJOR" -ge 8 ]; then
        success "MySQL $MYSQL_VERSION 已安装"
        MYSQL_INSTALLED=true
    else
        warn "当前 MySQL 版本为 $MYSQL_VERSION，需要 8.0+"
    fi
fi

if [ "$MYSQL_INSTALLED" = false ]; then
    warn "MySQL 8.0 未检测到，有两种选择："
    echo "  1. 本地安装 MySQL 8.0（适合开发测试）"
    echo "  2. 使用远程 MySQL（需要修改 application-dev.yml 中的数据库连接）"
    read -p "是否在本机安装 MySQL 8.0？(y/n): " INSTALL_MYSQL
    
    if [ "$INSTALL_MYSQL" = "y" ] || [ "$INSTALL_MYSQL" = "Y" ]; then
        info "正在安装 MySQL 8.0..."
        case "$PACKAGE_MANAGER" in
            brew)
                brew install mysql@8.0
                brew services start mysql@8.0
                ;;
            apt)
                sudo apt-get update
                sudo apt-get install -y mysql-server
                sudo systemctl start mysql
                sudo systemctl enable mysql
                ;;
            yum)
                sudo yum install -y mysql-community-server
                sudo systemctl start mysqld
                sudo systemctl enable mysqld
                ;;
        esac
        success "MySQL 8.0 安装并启动完成"
        
        # 初始化 root 密码（空密码，仅开发环境）
        info "初始化 MySQL root 用户（空密码，仅开发环境）..."
        mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';" 2>/dev/null || true
        mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        success "MySQL 初始化完成"
    else
        warn "跳过本地 MySQL 安装，请确保远程 MySQL 可访问并修改配置文件"
    fi
fi

###############################################################################
# Step 6: 克隆代码（如果尚未存在）
###############################################################################
info "[7/11] 检查代码仓库..."

if [ -d "$SERVER_DIR/.git" ] && [ -d "$WEB_DIR/.git" ]; then
    success "代码仓库已存在（$PROJECT_ROOT）"
else
    warn "代码未检出，正在从 GitHub 克隆到 $PROJECT_ROOT ..."
    
    # 确保目标目录存在
    mkdir -p "$PROJECT_ROOT"
    cd "$PROJECT_ROOT"
    
    if [ ! -d "family-home-server" ]; then
        git clone https://github.com/yanxing-mlp/MyHome.git family-home-server
        success "family-home-server 克隆完成"
    fi
    
    if [ ! -d "family-home-web" ]; then
        git clone https://github.com/yanxing-mlp/MyHome-Web.git family-home-web
        success "family-home-web 克隆完成"
    fi
fi

###############################################################################
# Step 7: 配置后端数据库连接
###############################################################################
info "[8/11] 配置后端数据库连接..."

DEV_YML="$SERVER_DIR/fh-boot/src/main/resources/application-dev.yml"

if [ ! -f "$DEV_YML" ]; then
    error "找不到配置文件: $DEV_YML"
fi

# 检查是否需要修改数据库连接
read -p "是否使用本地 MySQL（localhost:3306）？(y/n): " USE_LOCAL_DB

if [ "$USE_LOCAL_DB" = "y" ] || [ "$USE_LOCAL_DB" = "Y" ]; then
    DB_HOST="localhost"
    DB_PORT="3306"
    DB_NAME="family_home"
    DB_USER="root"
    DB_PASS=""
else
    read -p "请输入 MySQL 主机地址 (例如 192.168.1.100): " DB_HOST
    read -p "请输入 MySQL 端口 (默认 3306): " DB_PORT
    DB_PORT=${DB_PORT:-3306}
    read -p "请输入数据库名 (默认 family_home): " DB_NAME
    DB_NAME=${DB_NAME:-family_home}
    read -p "请输入数据库用户名: " DB_USER
    read -s -p "请输入数据库密码: " DB_PASS
    echo ""
fi

# 创建数据库（如果不存在）
info "创建数据库 $DB_NAME（如果不存在）..."
if [ -z "$DB_PASS" ]; then
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;" 2>/dev/null || \
        error "无法连接 MySQL，请检查连接参数"
else
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;" 2>/dev/null || \
        error "无法连接 MySQL，请检查连接参数"
fi
success "数据库 $DB_NAME 准备就绪"

# 自动使用 schema.sql 初始化数据库（开箱即用，无需手动操作）
SCHEMA_SQL="$SERVER_DIR/fh-boot/src/main/resources/db/schema.sql"
if [ -f "$SCHEMA_SQL" ]; then
    info "检测到完整数据库初始化脚本，正在执行..."
    
    if [ -z "$DB_PASS" ]; then
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" < "$SCHEMA_SQL" 2>/dev/null; then
            success "数据库已通过 schema.sql 初始化（包含种子数据）"
            # 禁用 Flyway baseline-on-migrate（因为表已存在）
            sed -i.bak 's/baseline-on-migrate: true/baseline-on-migrate: false/' "$DEV_YML"
            rm -f "$DEV_YML.bak"
        else
            warn "schema.sql 执行失败，将交由 Flyway 自动迁移"
        fi
    else
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SCHEMA_SQL" 2>/dev/null; then
            success "数据库已通过 schema.sql 初始化（包含种子数据）"
            # 禁用 Flyway baseline-on-migrate（因为表已存在）
            sed -i.bak 's/baseline-on-migrate: true/baseline-on-migrate: false/' "$DEV_YML"
            rm -f "$DEV_YML.bak"
        else
            warn "schema.sql 执行失败，将交由 Flyway 自动迁移"
        fi
    fi
else
    info "未找到 schema.sql，后端启动时将使用 Flyway 逐版本迁移"
fi

# 更新 application-dev.yml 中的数据库连接
info "更新数据库连接配置..."
sed -i.bak "s|jdbc:mysql://[^:]*:[^/]*/|jdbc:mysql://${DB_HOST}:${DB_PORT}/|" "$DEV_YML"
sed -i.bak "s|username:.*|username: ${DB_USER}|" "$DEV_YML"
sed -i.bak "s|password:.*|password: '${DB_PASS}'|" "$DEV_YML"
sed -i.bak "s|family_home_dev|${DB_NAME}|" "$DEV_YML"
rm -f "$DEV_YML.bak"
success "数据库配置已更新"

# 生成传输加密盐（前后端必须一致）
TRANSPORT_SALT=$(openssl rand -hex 16)
info "生成传输加密盐: $TRANSPORT_SALT"

# 更新后端配置
sed -i.bak "s|salt: \"\"|salt: \"${TRANSPORT_SALT}\"|" "$SERVER_DIR/fh-boot/src/main/resources/application-dev.yml"
rm -f "$SERVER_DIR/fh-boot/src/main/resources/application-dev.yml.bak"
success "后端传输加密盐已配置"

# 生成 vault 密钥（AES-256-GCM）
VAULT_KEY=$(openssl rand -base64 32)
info "生成 Vault 密钥: $VAULT_KEY"

sed -i.bak "s|password-key: \"\"|password-key: \"${VAULT_KEY}\"|" "$SERVER_DIR/fh-boot/src/main/resources/application-dev.yml"
rm -f "$SERVER_DIR/fh-boot/src/main/resources/application-dev.yml.bak"
success "Vault 密钥已配置"

###############################################################################
# Step 8: 构建并启动后端
###############################################################################
if [ "$MODE" = "full" ] || [ "$MODE" = "backend-only" ]; then
    info "[9/11] 构建并启动后端..."
    
    cd "$SERVER_DIR"
    
    # 编译打包
    info "执行 Maven 构建..."
    mvn clean package -DskipTests -q
    success "后端构建完成"
    
    # 创建文件存储目录
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
# Step 9: 配置前端环境变量
###############################################################################
if [ "$MODE" = "full" ] || [ "$MODE" = "frontend-only" ]; then
    info "[10/11] 配置前端环境变量..."
    
    # 创建 admin 的 .env.local
    ADMIN_ENV="$WEB_DIR/packages/admin/.env.local"
    cat > "$ADMIN_ENV" <<EOF
# 传输加密盐（必须与后端 application-dev.yml 中的 transport-crypto.salt 一致）
VITE_FH_TRANSPORT_CRYPTO_SALT=${TRANSPORT_SALT}
EOF
    success "admin .env.local 已创建"
    
    # 创建 h5 的 .env.local
    H5_ENV="$WEB_DIR/packages/h5/.env.local"
    cat > "$H5_ENV" <<EOF
# 传输加密盐（必须与后端 application-dev.yml 中的 transport-crypto.salt 一致）
VITE_FH_TRANSPORT_CRYPTO_SALT=${TRANSPORT_SALT}
EOF
    success "h5 .env.local 已创建"
    
    ###############################################################################
    # Step 10: 安装依赖并启动前端
    ###############################################################################
    info "[11/11] 安装前端依赖并启动..."
    
    cd "$WEB_DIR"
    
    # 安装依赖
    info "执行 pnpm install..."
    pnpm install
    success "前端依赖安装完成"
    
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
success "MyHome 系统部署完成！"
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
info "初始账号："
echo "  - 大宝（ADMIN）: 手机号 13800138000，密码 123456"
echo "  - 小宝（MEMBER）: 手机号 13800138001，密码 123456"
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
info "停止服务："
if [ "$MODE" = "full" ] || [ "$MODE" = "backend-only" ]; then
    echo "  kill \$(cat /tmp/family-home-backend.pid)"
fi
if [ "$MODE" = "full" ] || [ "$MODE" = "frontend-only" ]; then
    echo "  kill \$(cat /tmp/family-home-admin.pid)"
    echo "  kill \$(cat /tmp/family-home-h5.pid)"
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
success "祝使用愉快！🎉"
