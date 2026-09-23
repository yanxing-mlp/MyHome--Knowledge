# MyHome 系统部署指南

## 快速开始：一键部署

### 前置条件

- **操作系统**：macOS（推荐）或 Linux（Ubuntu/Debian/CentOS）
- **网络**：能访问 GitHub、MySQL（本地或远程）
- **权限**：需要 sudo 权限安装系统软件包

### 一键部署步骤

```bash
# 1. 克隆知识库仓库
git clone https://github.com/yanxing-mlp/MyHome--Knowledge.git
cd MyHome-Knowledge

# 2. 运行一键部署脚本
bash deployment/one-click-deploy.sh
```

脚本会自动完成以下操作：

1. **检测操作系统与包管理器**（Homebrew / apt-get / yum）
2. **安装 JDK 21**（Spring Boot 3.5 必需）
3. **安装 Maven 3.9+**（后端构建工具）
4. **安装 Node.js 22+ 与 pnpm**（前端构建环境）
5. **安装 MySQL 8.0**（可选，也可连接远程数据库）
6. **克隆代码仓库**（family-home-server + family-home-web）
7. **配置数据库连接**（生成本地数据库或填写远程连接信息）
8. **构建并启动后端**（Spring Boot + Flyway 自动建表）
9. **配置前端环境变量**（传输加密盐、Vault 密钥）
10. **安装依赖并启动前端**（B 端管理后台 + C 端 H5）

### 部署模式

```bash
# 完整部署（后端 + 前后端）
bash deployment/one-click-deploy.sh

# 只部署后端
bash deployment/one-click-deploy.sh --backend-only

# 只部署前端（需确保后端已运行）
bash deployment/one-click-deploy.sh --frontend-only
```

---

## 日常运维：重启与更新

完成首次部署后，日常开发中需要拉取最新代码并重启服务，使用专用脚本更快捷。

### 重启脚本用法

```bash
# 完整重启（拉取代码 + 重新构建 + 启动）
bash deployment/restart.sh

# 只重启后端
bash deployment/restart.sh --backend-only

# 只重启前端
bash deployment/restart.sh --frontend-only

# 跳过 git pull（本地调试用）
bash restart.sh --skip-pull

# 跳过构建（仅重启，适合配置未变时）
bash restart.sh --skip-build
```

### 重启流程

脚本会自动执行以下步骤：

1. **停止正在运行的服务**：通过 PID 文件或端口查找，优雅停止所有进程
2. **拉取最新代码**：检测远程新提交并更新本地仓库（可跳过）
3. **检查依赖**：如果 `package.json` 有变化，自动执行 `pnpm install`
4. **重新构建**：清理旧产物并编译打包（可跳过）
5. **启动服务**：后台启动后端和前端，记录 PID 和日志
6. **等待就绪**：轮询健康检查接口，确认服务可用

### 日志管理

每次重启会自动轮转日志文件，保留最近 7 天的历史：

```bash
# 查看当前日志
tail -f /tmp/family-home-backend.log
tail -f /tmp/family-home-admin.log
tail -f /tmp/family-home-h5.log

# 查看历史日志（按时间戳命名）
ls -lh /tmp/family-home-*.log.*
```

### 常见场景

| 场景 | 命令 |
|------|------|
| 早上开始工作，拉取最新代码重启 | `bash restart.sh` |
| 改了后端代码，只重启后端 | `bash restart.sh --backend-only --skip-pull` |
| 改了前端样式，只重启前端 | `bash restart.sh --frontend-only --skip-pull` |
| 配置未变，快速重启 | `bash restart.sh --skip-build` |
| 排查问题，查看版本信息 | 重启完成后会输出两端 commit hash |

### 访问地址

部署完成后，可访问以下地址：

- **后端健康检查**：http://localhost:8080/health
- **B 端管理后台**：http://localhost:5173/admin/
- **C 端 H5**：http://localhost:5174/

### 初始账号

系统会自动创建两个初始账号：

| 昵称 | 角色 | 手机号 | 密码 | 说明 |
|------|------|--------|------|------|
| 大宝 | ADMIN | 13800138000 | 123456 | 管理员，可管理所有模块 |
| 小宝 | MEMBER | 13800138001 | 123456 | 普通成员，可使用 C 端功能 |

### 日志位置

```bash
# 后端日志
tail -f /tmp/family-home-backend.log

# B 端管理后台日志
tail -f /tmp/family-home-admin.log

# C 端 H5 日志
tail -f /tmp/family-home-h5.log
```

### 停止服务

```bash
# 停止后端
kill $(cat /tmp/family-home-backend.pid)

# 停止 B 端
kill $(cat /tmp/family-home-admin.pid)

# 停止 C 端
kill $(cat /tmp/family-home-h5.pid)
```

---

## 手动部署（高级用户）

如果一键部署脚本不适用你的环境，可以按以下步骤手动部署。

### 1. 安装开发环境

#### macOS（使用 Homebrew）

```bash
# 安装 JDK 21
brew install openjdk@21
export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
export PATH="$JAVA_HOME/bin:$PATH"

# 安装 Maven
brew install maven

# 安装 Node.js 22
brew install node@22

# 安装 pnpm
npm install -g pnpm

# 安装 MySQL 8.0（可选）
brew install mysql@8.0
brew services start mysql@8.0
```

#### Linux（Ubuntu/Debian）

```bash
# 安装 JDK 21
sudo apt-get update
sudo apt-get install -y openjdk-21-jdk
export JAVA_HOME="/usr/lib/jvm/java-21-openjdk"
export PATH="$JAVA_HOME/bin:$PATH"

# 安装 Maven
sudo apt-get install -y maven

# 安装 Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# 安装 pnpm
npm install -g pnpm

# 安装 MySQL 8.0（可选）
sudo apt-get install -y mysql-server
sudo systemctl start mysql
sudo systemctl enable mysql
```

### 2. 准备数据库

```sql
-- 创建数据库
CREATE DATABASE IF NOT EXISTS `family_home` 
  DEFAULT CHARACTER SET utf8mb4 
  COLLATE utf8mb4_0900_ai_ci;

-- 创建用户（可选，生产环境建议单独建用户）
CREATE USER 'family_home'@'localhost' IDENTIFIED BY 'your_password';
GRANT ALL PRIVILEGES ON `family_home`.* TO 'family_home'@'localhost';
FLUSH PRIVILEGES;
```

### 3. 克隆代码

```bash
# 后端
git clone https://github.com/yanxing-mlp/MyHome.git family-home-server

# 前端
git clone https://github.com/yanxing-mlp/MyHome-Web.git family-home-web
```

### 4. 配置后端

编辑 `family-home-server/fh-boot/src/main/resources/application-dev.yml`：

```yaml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/family_home?useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true
    username: root
    password: ""  # 改为你的数据库密码

fh:
  storage:
    root: /data/family-home/files  # 文件存储根目录
    url-prefix: /files
  
  vault:
    password-key: "YOUR_BASE64_32_BYTES_KEY"  # openssl rand -base64 32
  
  transport-crypto:
    salt: "YOUR_HEX_16_BYTES_SALT"  # openssl rand -hex 16
```

生成密钥：

```bash
# Vault 密钥（AES-256-GCM）
openssl rand -base64 32

# 传输加密盐（前后端必须一致）
openssl rand -hex 16
```

### 5. 构建并启动后端

```bash
cd family-home-server

# 编译打包
mvn clean package -DskipTests

# 创建文件存储目录
sudo mkdir -p /data/family-home/files
sudo chmod 777 /data/family-home/files

# 启动后端
java -jar fh-boot/target/fh-boot-1.0.0-SNAPSHOT.jar \
  --spring.profiles.active=dev
```

后端将在 http://localhost:8080 启动，Flyway 会自动执行所有迁移脚本建表。

### 6. 配置前端

创建 `family-home-web/packages/admin/.env.local`：

```env
VITE_FH_TRANSPORT_CRYPTO_SALT=YOUR_HEX_16_BYTES_SALT
```

创建 `family-home-web/packages/h5/.env.local`：

```env
VITE_FH_TRANSPORT_CRYPTO_SALT=YOUR_HEX_16_BYTES_SALT
```

**注意**：这里的盐必须与后端 `application-dev.yml` 中的 `transport-crypto.salt` 完全一致。

### 7. 安装依赖并启动前端

```bash
cd family-home-web

# 安装依赖
pnpm install

# 启动 B 端管理后台（新终端窗口）
pnpm dev:admin

# 启动 C 端 H5（新终端窗口）
pnpm dev:h5
```

前端将分别在：
- B 端：http://localhost:5173/admin/
- C 端：http://localhost:5174/

---

## 常见问题

### 1. 后端启动失败：Flyway 迁移版本号冲突

**症状**：
```
Found more than one migration with version 201
```

**原因**：多个域使用了相同的 Flyway 版本号。

**解决**：确保每个域的迁移文件版本号全局唯一：
- file 域：V1xx
- album 域：V2xx
- recipe 域：V3xx
- vault 域：V4xx
- user 域：V5xx

### 2. 前端登录报错："口令无法解密"

**原因**：前后端的传输加密盐不一致。

**解决**：检查以下两处配置是否完全一致：
- 后端：`fh-boot/src/main/resources/application-dev.yml` 中的 `transport-crypto.salt`
- 前端：`packages/admin/.env.local` 和 `packages/h5/.env.local` 中的 `VITE_FH_TRANSPORT_CRYPTO_SALT`

### 3. 图片上传失败：413 Request Entity Too Large

**原因**：nginx 或 Spring Boot 限制了上传文件大小。

**解决**：
- Spring Boot：检查 `application.yml` 中的 `spring.servlet.multipart.max-file-size`（默认 500MB）
- nginx：在 server 块中添加 `client_max_body_size 500m;`

### 4. 视频无法播放：HTTP Range 不支持

**原因**：静态资源映射未使用 `FileSystemResource`。

**解决**：确保视频播放接口返回的是 `FileSystemResource` 而非 `InputStreamResource`，前者支持 HTTP Range/206 分片请求。

### 5. 数据库连接失败：Access denied

**原因**：数据库用户名/密码错误，或用户没有权限。

**解决**：
```sql
-- 检查用户权限
SHOW GRANTS FOR 'family_home'@'localhost';

-- 重新授权
GRANT ALL PRIVILEGES ON `family_home`.* TO 'family_home'@'localhost';
FLUSH PRIVILEGES;
```

### 6. 端口被占用

**症状**：
```
Port 8080 was already in use
```

**解决**：修改配置文件中的端口，或杀掉占用进程：
```bash
# macOS
lsof -ti:8080 | xargs kill -9

# Linux
sudo fuser -k 8080/tcp
```

---

## 生产环境部署建议

### 1. 安全加固

- **启用 HTTPS**：使用 Let's Encrypt 免费证书，或在阿里云/腾讯云申请 SSL 证书
- **修改默认密码**：首次登录后立即修改初始账号密码
- **限制管理员可见性**：ADMIN 账号不应暴露给所有用户
- **关闭 dev-seed**：生产环境不要启用数据种子，避免脏数据

### 2. 性能优化

- **数据库连接池**：调整 HikariCP 参数（`spring.datasource.hikari.maximum-pool-size`）
- **文件存储**：考虑使用 OSS/S3 替代本地文件系统
- **CDN 加速**：静态资源（图片、视频）走 CDN
- **缓存策略**：Redis 缓存热点数据（菜谱列表、相册封面）

### 3. 监控与告警

- **应用监控**：接入 Sunfire/Prometheus/Grafana
- **日志收集**：ELK/SLS 集中管理日志
- **健康检查**：定期探测 `/health` 接口
- **备份策略**：每日全量备份数据库，保留 7 天

### 4. 高可用架构

```
                    ┌─────────────┐
                    │   SLB/Nginx  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
      ┌───────▼───┐ ┌─────▼────┐ ┌────▼──────┐
      │ App Node 1│ │App Node 2│ │App Node 3 │
      └───────┬───┘ └─────┬────┘ └────┬──────┘
              │            │            │
              └────────────┼────────────┘
                           │
                  ┌────────▼────────┐
                  │  MySQL 主从集群   │
                  └─────────────────┘
```

---

## 技术支持

如有问题，请查阅：

- [系统架构文档](../architecture/system-overview.md)
- [开发规范](../development-standards/coding-conventions.md)
- [项目决策记录](../memories/project-decisions/README.md)
- [用户反馈汇总](../memories/feedback/README.md)

或在 GitHub Issues 中提问：
- [family-home-server Issues](https://github.com/yanxing-mlp/MyHome/issues)
- [family-home-web Issues](https://github.com/yanxing-mlp/MyHome-Web/issues)
