# MyHome 部署说明

## 交付形态：一个离线总包 · 三平台 · 产物直跑

交付物是**一个总压缩包** `MyHome-Offline.zip`，内部按平台分三个子目录，外加一份共享执行说明：

```text
MyHome-Offline/
├── 执行说明.md            # 三平台共享（含平台差异表），LF 无 BOM
├── windows-x64/           # Windows 10/11 Intel/AMD x64
├── macos-arm64/           # macOS Apple Silicon（arm64）
└── linux-x64/             # Ubuntu/Debian x86_64
```

每个平台子目录都自带：入口脚本、引擎脚本、`packages.json`（工具链清单 + 端口 + 传输盐）、本平台编码的 `执行说明.md`，以及 `runtime/`（哈希校验过的工具链 + 应用产物包）。

**模型：产物直跑（v57）。** 应用不再随包携带源码、部署时也不再 `git clone` / `mvn` / `pnpm` / `node`。构建流水线（`build-payload.py`）在打包机上把后端 fat JAR、两份已构建的前端 dist、schema 快照与版本戳压成一个 **应用产物包** `MyHome-app-payload.zip`，随每个平台的 `runtime/` 一起捆绑并核对 SHA-256。首次部署把它解到 `<install>/app/`，用 `java -jar` 起后端；后端**单端口**（8080）同时托管两份 dist，前后端同源、无需任何反向代理。

> 旧的「联网源码直跑」模型（v53，部署时 git clone 两仓 + `mvn spring-boot:run` + `pnpm dev`，工具链含 Node/Maven/pnpm/Git）以及更早的「离线预编译总包」（586 MB）已全部退役删除，不要混用。

### 运行拓扑（Topology A：后端单端口托管前端）

只有两个监听端口，都只绑 `127.0.0.1`：

- **后端 8080** —— `java -jar app/family-home-server.jar`。同时把两份 dist 当静态资源发出：`/admin/**` 出 B 端管理后台、`/**` 出 C 端（h5）。
- **私有 MySQL 13306** —— 数据落 `<install>/data/mysql`，绝不接管系统 MySQL。

前端两份 dist 不再各占端口（旧的 5173 / 5174 已随源码直跑模型退役）。前后端同源，天然规避跨域与传输盐不同源问题。

### 应用产物目录 `app/`（首次部署解包生成）

```text
<install>/app/
├── family-home-server.jar   # 后端 fat JAR；Flyway 迁移随 classpath 一起发布
├── admin/                   # B 端已构建 dist（后端在 /admin/** 托管）
├── h5/                      # C 端已构建 dist（后端在 /** 托管）
├── schema-snapshot.sql      # 新库冷启动用的「结构 + 种子 + 真 Flyway 历史」快照
└── version.json             # 版本戳：version / transportSalt / 两仓 commit / payload 哈希
```

- **「部署包的 SQL」= 重新构建 JAR 即自动更新**，不存在独立维护的 `.sql` 迁移文件。首次部署与每次更新都由后端启动时的 Flyway 从 JAR 的 classpath 自动应用新迁移（升级路径）。
- **新库冷启动**：空库若让 Flyway 按版本号严格重放会炸在 V103（file 域 V1xx 却引用 album/recipe 表）。故产物包额外带一份 `schema-snapshot.sql`（由 `gen-schema-snapshot.py` 分阶段跑出**真** Flyway history 再 dump 得到，不伪造 / 不 baseline / 不 repair）。引擎冷启动时若 `family_home` 零表，先 load 快照再起后端；后端 Flyway 见到完整 history 直接 no-op。

## 三平台入口与引擎

| 平台 | 入口脚本 | 引擎 | 默认安装目录 |
|---|---|---|---|
| windows-x64 | `01-deploy.cmd` / `02-start.cmd` / `03-stop.cmd` / `04-update.cmd` | `myhome-windows.ps1`（PowerShell 5.1） | `%LOCALAPPDATA%\MyHome` |
| macos-arm64 | `01-deploy.sh` / `02-start.sh` / `03-stop.sh` / `04-update.sh` | `myhome-unix.sh`（bash） | `~/Library/Application Support/MyHome` |
| linux-x64 | 同上（`.sh`） | `myhome-unix.sh`（bash） | `~/.local/share/MyHome` |

`myhome-unix.sh` 是 macOS 与 Linux 共用的同一份引擎，靠 `uname -s` 分流（Darwin→期望 arm64，Linux→期望 x86_64），两平台子目录里是同一字节内容。四个 `.sh` 入口只是 `cd` 到自身目录后 `exec bash myhome-unix.sh --action <deploy|start|stop|update> "$@"`。（`update` 动作走本地升级：解包本离线包 `runtime/` 内携带的新产物包，不再联网下载；早期供后端「部署最新」按钮分离拉起的 `deploy-now.sh` 已随在线通道一并删除。）

**产物直跑不需要 Git**：应用不再现场克隆编译，工具链只保留运行必需的 **JDK 21** 与 **MySQL 8.4**（Windows 另含 **VC++ 运行库**），随包携带并逐个核对 SHA-256，缺失或不符即拒绝部署。

安装目录可用 `--install-dir DIR`（或环境变量 `MYHOME_INSTALL_DIR`）覆盖；启停、升级必须始终用同一目录、同一账号。运行目录布局：`app/`（解包后的产物）、`data/{mysql,files,files-private}`、`state`、`tools`（JDK + MySQL）、`logs`。

## 升级通道：手动放置新的离线部署包（全程离线）

本系统是**离线部署包**，没有任何在线升级入口，引擎与后端都绝不联网下载。升级到新版本 = 由维护者构建并交付一个**新的离线部署包**（新的 `MyHome-Offline.zip`，其 `runtime/` 内携带新的 `MyHome-app-payload.zip`），用户手动把它完整复制到部署机、全部解压，然后在对应平台子目录跑 `update` 动作：

- **命令行**：跑 `04-update.sh` / `04-update.cmd`。

`update` 动作流程：读取本离线包 `packages.json` 的 `app` 段 → **校验随包 `runtime/MyHome-app-payload.zip` 的 SHA-256** → 解到 `app.new` → 读取其 `version.json` 比对版本（与当前运行一致则提示无需替换、正常退出）→ 停后端 → 原子替换 `<install>/app/`（`app.new` 就位后与旧 `app/` 互换，旧目录留 `app.old`）→ 重启后端（Flyway 随新 JAR 的 classpath 自动补跑增量迁移）。校验通过前绝不触碰现有 `app/`。**全程离线，不需要网络。**

> 早期版本（v57）曾提供「GitHub Release 在线拉取升级」通道（后端 `DeployService` 拉最新发布、前端「部署管理」页「部署最新」按钮 + 实时进度面板、引擎 `deploy-now.*` 分离触发）。该通道已**整体移除**：`packages.json` 不再有 `update` 段且 `offline:true`，后端只保留 `capability` + `部署历史` 只读接口，前端「部署管理」页只剩当前版本卡 + 部署历史，「系统日志」页不变。

## 密钥与数据

- Windows：`state` 内数据库口令、密码本密钥、登录密钥、传输盐用 **DPAPI** 保护（绑定原电脑 + 原 Windows 账号）。
- macOS / Linux：无 DPAPI，改用 `0600` 的 `secrets.env` + `0700` 的 `state` 目录权限保护。

三平台都只监听 loopback（后端 8080、私有 MySQL 13306），只支持本机访问；不改防火墙、全局环境变量/执行策略或电源设置，不建开机任务。手机、局域网、公网、HTTPS 不在范围内。

必须同时保留 `data`（含私有 MySQL）与整个 `state`。备份前先正常停止应用与数据库。复制目录不等于支持换机恢复（密钥绑定原机/原账号）。

## 初始化口径（三平台一致）

只初始化，不导入测试业务数据：保留大宝/小宝两个账号（初始密码均 `123456`，登录后各自到个人中心修改）、文件分类、菜品分类/做法基础字典、购物车版本状态与迁移历史；相册、图片、视频、文档、菜品、购物车条目、订单、密码本从空开始。重复部署不删已有业务内容、不重置账号密码。

新库冷启动通过 load 构建期生成的 `schema-snapshot.sql`（内含**真** Flyway history）实现，绕开 V103 在空库上按版本号严格重放的崩溃；这份快照由 `gen-schema-snapshot.py` 分阶段跑真迁移再 dump 得到，**不伪造 history、不 baseline、不执行 repair、不跑演示造数脚本**。升级路径（已有库）不碰快照，由 Flyway 从 JAR classpath 自动补增量迁移。

## 打包

两步流水线（均在打包机上跑，不改任何源文件）：

1. **`offline-deploy-build/build-payload.py`** —— 产出**应用产物包**。`mvn clean package`（JDK 21）出后端 fat JAR + `pnpm build`（注入固定传输盐 `VITE_FH_TRANSPORT_CRYPTO_SALT`）出两份 dist + `gen-schema-snapshot.py` 出 schema 快照，组装成 `payload/` 再压成 `MyHome-app-payload.zip`，同时产出独立 `version.json`（= 内层版本戳 + payload 自描述块 `{file,sha256,bytes}`）与 `.zip.sha256`。这份产物包随后由 `package-master.py` 捆绑进每个平台的 `runtime/`（不再单独发布到任何在线仓库）。
2. **`offline-deploy-build/package-master.py`** —— 生成三平台离线总包 `MyHome-Offline.zip`（当前交付物）。逐平台校验 `packages.json`（formatVersion=4 / offline=true / runMode=artifact / platform 匹配 / 不含 `update` 段）与每个工具链归档的 SHA-256，把产物包塞进各平台 `runtime/`，并**按实际捆绑的 payload zip 重写 `packages.json` 的 `app.hash` / `app.version`**，再按平台编码规则暂存、组装、压缩。归一化只发生在暂存副本上。

编码规则：Windows `.ps1`/`使用说明.txt`/`执行说明.md` = UTF-8 BOM + CRLF；Windows `.cmd` = CRLF 无 BOM（cmd.exe 遇 BOM 会报错）；`packages.json` = 原字节无 BOM；Unix `.sh`/`执行说明.md`/`packages.json` = LF 无 BOM，`.sh` 带可执行位；`runtime/*` 归档与产物包 = ZIP_STORED（本身已压缩，不再二次压缩）。

工具链归档分别存放在工作区根的 `windows-deploy-checks/`、`macos-deploy-checks/`、`linux-deploy-checks/`，由 `package-master.py` 读取核对。

## 失败排查

失败时窗口会显示具体步骤、原因、退出码与日志路径。默认日志目录为安装目录下 `logs/`：首次部署看 `Deploy.log`，启动看 `Start.log`，停止看 `Stop.log`，升级看 `Update.log`；服务相关为 `server.log`、`backend.err.log`、`mysql-error.log` 等。日志创建前的失败以窗口原始错误为准。管理后台「系统日志」页（仅超管）可实时 tail 这些 `.log`。

缺工具链文件、产物包或哈希不符→重新完整复制同版本包；升级失败→确认 `04-update.*` 是在**新的离线部署包**的平台子目录里运行的（该包 `runtime/` 内带新产物包），全程离线不需网络；端口冲突→只处理已确认属于自己的程序。不删 `data`/`state`/密钥文件，不清库、不重置 root 认证、不关系统防护来重试。分享日志前检查隐私，不发送 `state`、`secrets.xml`（Windows）、`secrets.env`（Unix）、`mysql-client.ini`/`mysql-client.cnf`、`mysql-init.sql`、`config.json`。

完整命令、成功判据（脚本返回码 + 健康检查 + 浏览器）与平台差异表见 [执行说明.md](执行说明.md)。

## 验证边界

制作环境为 macOS（Apple Silicon）。`myhome-unix.sh` 引擎已在真机 macOS arm64 上功能验证：工具链（JDK + MySQL）解包 + 探针 + 版本、产物包解包到 `app/`、幂等重装、密钥与传输盐、`runtime.env` 往返、完整 MySQL 生命周期（initialize-insecure → init-file 建库建用户 → SELECT → mysqladmin shutdown → 重启后数据仍在）、新库冷启动 load schema 快照、单端口 Topology A（后端 `/api/b/health` + `/admin/` + `/` 同源可达）。「部署管理」页当前保留「当前运行版本」卡 + 部署历史（只读 `logs/deploy-history.json`），「系统日志」页实时 tail 均已验证；早期的在线「部署最新」按钮 + 实时进度面板曾验证过，但随在线通道整体移除后已下线。

**尚未完成**：本地升级（`04-update.*` 解包本离线包内新产物并原子替换）在真机上尚未跑过完整替换链路、Linux x64 真机、Windows 真机（PowerShell 5.1 / UAC / DPAPI / NTFS / MySQL 8.4 / `myhome-windows.ps1` 的自重启与本地升级替换）的原生全流程验收——ps1 侧仅 macOS 静态审查，本机无 pwsh 无法执行。macOS 隔离回归不能证明 Linux 的 apt/systemd 与 Windows 原生执行可用。本版不能标为已完成三平台原生全流程验收。
