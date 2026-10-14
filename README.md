# MyHome 家庭管理系统 - 知识库

本项目整理了 MyHome 家庭管理系统的完整知识库，包括架构设计、技术栈、开发规范、业务口径和实践经验。

## 目录结构

```
MyHome--Knowledge/
├── README.md                        # 本文件
├── architecture/
│   └── system-overview.md           # 系统总览（技术栈/架构原则/模块边界/C 端能力边界/风险）
├── assets/
│   ├── architecture-diagram.png     # 系统架构图（v31 版渲染产物）
│   └── architecture-diagram.svg     # 架构图源文件（改图改它，再渲染成 png）
├── development-standards/
│   └── coding-conventions.md        # 编码规范
├── memories/                        # 记忆点（经验教训）
│   ├── feedback/README.md           # 用户反馈与行为模式
│   └── project-decisions/README.md  # 项目决策记录（30 条，含 v24~v31 演进）
├── plans/
│   └── phase1-roadmap.md            # 一期方案（含完整变更记录，当前 v31）
└── deployment/                      # 部署脚本
    ├── README.md                    # 部署指南（一键部署 + 手动部署 + FAQ + 生产建议）
    ├── one-click-deploy.sh          # 从零搭建全环境（Git/JDK/Maven/Node/pnpm/MySQL + 建库 + 启动）
    └── restart.sh                   # 日常拉取最新代码 + 重新构建 + 重启
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
- 👤 **账号体系**：多用户登录、权限管理、个人中心

**公私域（Domain）**：B/C 两端导航都按「家庭 / 个人」收敛，家庭里的东西全家可见，个人里的东西仅自己可见；一个全局域开关切换，不再让公私两套入口同屏冗余并存。

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

## 部署

`deployment/` 下两个脚本：

- **`one-click-deploy.sh`**：从零搭建全环境（Git/JDK/Maven/Node/pnpm/MySQL 安装、schema.sql 自动初始化、密钥生成、前后端启动），开箱即用
- **`restart.sh`**：日常拉取最新代码 + 重新构建 + 重启（支持 `--backend-only` / `--frontend-only` / `--skip-pull` / `--skip-build`）

详见 [deployment/README.md](deployment/README.md)。

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

*最后更新：2026-10-13*
