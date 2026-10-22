# MyHome 家庭管理系统 - 知识库

本项目整理了 MyHome 家庭管理系统的完整知识库，包括架构设计、技术栈、开发规范、业务口径和实践经验。

## 目录结构

```
MyHome--Knowledge/
├── README.md                        # 本文件
├── architecture/
│   └── system-overview.md           # 系统总览（技术栈/架构原则/模块边界/系统后台与 RBAC/C 端能力边界/风险）
├── assets/
│   ├── architecture-diagram.png     # 系统架构图（v56 版渲染产物）
│   └── architecture-diagram.svg     # 架构图源文件（改图改它，再渲染成 png）
├── development-standards/
│   └── coding-conventions.md        # 编码规范
├── memories/                        # 记忆点（经验教训）
│   ├── feedback/README.md           # 用户反馈与行为模式
│   └── project-decisions/README.md  # 项目决策记录（含 v24~v56 演进，系统后台/RBAC/数据库页等）
├── plans/
│   └── phase1-roadmap.md            # 一期方案（含完整变更记录，当前 v56）
└── deployment/                      # 部署脚本（联网源码直跑 · 三平台）
    ├── README.md                    # 部署指南（总包结构 + 三平台入口 + 打包 + 验证边界）
    ├── 执行说明.md                   # 三平台共享执行说明（含平台差异表）
    ├── windows/                     # Windows x64：.cmd 入口 + myhome-windows.ps1 + packages.json
    ├── macos-arm64/                 # macOS Apple Silicon：packages.json（.sh 入口/引擎在 common/）
    ├── linux-x64/                   # Ubuntu/Debian x64：packages.json（.sh 入口/引擎在 common/）
    └── common/                      # macOS/Linux 共用：.sh 入口 + myhome-unix.sh 引擎
```

> `plans/phase1-roadmap.md` 是开发工作区 `plans/家庭home-一期方案.md` 的镜像副本，其余文档是基于方案提炼的精简版，需随新增决策手动补条目。

## 系统架构图

![MyHome Architecture](assets/architecture-diagram.png)

## 快速开始

### 核心概念

**MyHome** 是一个面向家庭的综合管理系统，涵盖：
- 📸 **相册管理**：家庭相册 + 私人相册，支持分组、城市分布、图片上传（B/C 两端均可上传）
- 🍳 **菜谱管理**：菜品分类、做法配置、点餐下单、订单统计（家庭共享，无个人版）
- 🎥 **视频管理**：家庭视频 + 私人视频，分组两级页、原生播放，C 端可上传不可删
- 📁 **文件管理**：文档上传 + 分组（仅 B 端，不下沉 C 端）
- 🔐 **密码本**：账号密码保管，传输层加密，C 端只读（能列表 + 取回口令）
- 👤 **账号体系**：多用户登录、三档固定角色（超级管理员/普通管理员/普通成员）、个人中心
- 🛠️ **系统后台**：仅 B 端、按权限逐页露出的一组运维/治理页——账号管理、角色管理、目录管理、变更记录、部署管理、系统日志、操作记录、知识库、后端代码、前端代码、数据库（共 11 项）

**公私域（Domain）**：B/C 两端导航都按「家庭 / 个人」收敛，家庭里的东西全家可见，个人里的东西仅自己可见；一个全局域开关切换，不再让公私两套入口同屏冗余并存。

**三档角色 RBAC**：`SUPER_ADMIN / ADMIN / MEMBER` 三档固定枚举，权限项也是固定的一批（`PermissionCatalog`，共 23 码：6 个业务模块各 `.view`/`.manage` 两档 + 11 个系统后台页各一个 `.access`）；可配置的只有「某档勾选了哪些权限」这一层（存 `role_permission` 表，超管在「角色管理」页调）。超级管理员在 `can()` 里短路拥有全部权限、且全系统只能有一个（不可交接、不可删、不可提第二人）。

### 技术架构

- **后端**：Spring Boot 3.5 + Java 21 + MyBatis-Plus + Flyway
- **前端**：React 19 + TypeScript 5.9 + Vite 8 + pnpm monorepo（admin = B 端 antd v6 / h5 = C 端零组件库 / shared）
- **数据库**：MySQL 8.0
- **存储**：本地文件系统 + FileSystemResource（HTTP Range 支持），图片视频保留原件、前端不压缩

### 关键特性

1. **数据分区隔离**：PUBLIC（公共）/ PRIVATE（个人）双域隔离，ADMIN 无例外，跨区裸 ID 404
2. **公私域驱动导航**：B 端以 URL 为准 + localStorage 兜底，C 端只存本机、切域不跳路由
3. **会话令牌认证**：HMAC-SHA256 签名 Bearer Token，7天有效期
4. **传输层加密**：口令传输 AES 加盐加密（硬约束 https/localhost）
5. **版本化购物车**：共享购物车原子幂等消费，一人一菜一行（同菜不同加购人各占一行）
6. **预签名流式播放**：VideoPlayTicket 6h 签名票据（不复用登录令牌）
7. **C 端能力边界**：相册/视频能看能传不能删，密码本纯只读，文档不下沉，管理动作一律留 B 端
8. **三档角色 RBAC + 可编辑权限矩阵**：写操作与系统后台接口后端逐个 `requirePermission`，业务读接口只要登录态；`.view` 只驱动前端菜单/路由 403。角色固定三档、权限项固定 23 码，超管在「角色管理」页勾选每档权限（`role_permission` 表）
9. **系统后台可观测性**：变更记录（GitHub API 实时优先 + 构建期快照兜底，标「当前运行版本」）、部署管理（分离 launcher 拉起 + 进度文件跨重启接续 + 部署历史）、系统日志（多文件切换 + 实时 tail + 保留天数驱动 logback）、操作记录（读写全审计 + B/C 端区分 + 出入参脱敏 + 单请求 traceId 关联日志回溯）
10. **在线仓库编辑**：知识库 / 后端代码 / 前端代码三页共用 `RepoService` 引擎，浏览目录树 + 编辑文本文件 + 本地保存 + 一键 `git add/commit/push`（进程内同步跑，与部署的分离 launcher 本质不同）
11. **可视化数据库管理**：仅超管可达（`database.access`，全系统权限最高页），表数据行内增删查改 + 结构化改表结构（含表级说明）+ 只读索引清单 + 任意 SQL（写/DDL 前端二次确认）+ 每日 mysqldump 备份与保留天数

## 部署

交付物是一个总包 `MyHome-OneClick.zip`，内含 `windows-x64/`、`macos-arm64/`、`linux-x64/` 三个平台子目录和一份共享 `执行说明.md`。模型是**联网 · 源码直跑**：工具链（JDK/Node/Maven/pnpm/MySQL，Windows 另含 Git/VC++）随包提供并核对哈希，应用源码部署时按 `packages.json` 联网克隆，后端 `mvn spring-boot:run`、前端 `pnpm dev` 直接跑。

- **Windows**：`01-deploy.cmd` / `02-start.cmd` / `03-stop.cmd` / `04-update.cmd`，引擎 `myhome-windows.ps1`。
- **macOS / Linux**：同名 `.sh` 入口，共用引擎 `common/myhome-unix.sh`（靠 `uname` 分流）。

旧的离线预编译总包及 `one-click-deploy.sh` / `restart.sh` / `unix-deploy.py` / `offline-env.sh` 已退役删除。详见 [deployment/README.md](deployment/README.md)。

## 使用说明

本知识库适用于：
- 新成员快速了解项目架构和业务逻辑
- 开发人员查阅编码规范和最佳实践
- 产品经理理解功能设计和用户故事
- 运维人员排查问题和部署系统

## 维护说明

- **记忆点**：来自实际开发过程中的经验教训和用户反馈
- **方案文档**：记录各阶段的设计决策和实施细节
- **技术规范**：随项目演进持续更新
- **架构图**：`assets/architecture-diagram.svg` 是唯一图源，png 只是渲染产物。改图只改 svg，然后：
  `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=1792,1024 --screenshot=assets/architecture-diagram.png assets/architecture-diagram.svg`
  （任何 headless Chrome 都行；`--force-device-scale-factor=2` 出 2 倍图保证文字清晰）

---

*最后更新：2026-10-22*
