# MyHome 部署说明

## 交付形态：一个总包 · 三平台 · 联网源码直跑

交付物是**一个总压缩包** `MyHome-OneClick.zip`，内部按平台分三个子目录，外加一份共享执行说明：

```text
MyHome-OneClick/
├── 执行说明.md            # 三平台共享（含平台差异表），LF 无 BOM
├── windows-x64/           # Windows 10/11 Intel/AMD x64
├── macos-arm64/           # macOS Apple Silicon（arm64）
└── linux-x64/             # Ubuntu/Debian x86_64
```

每个平台子目录都自带：入口脚本、引擎脚本、`packages.json`（工具链清单 + 仓库地址 + 端口 + 传输盐）、本平台编码的 `执行说明.md`，以及 `runtime/`（哈希校验过的完整工具链）。

**模型：联网 · 源码直跑。** 工具链（JDK 21、Node 22、Maven、pnpm、MySQL 8.4，Windows 另含 Git 与 VC++）随包提供并逐个核对 SHA-256；应用源码**不**随包携带，部署时按 `packages.json` 里的 GitHub 地址联网克隆，后端 `mvn spring-boot:run`、前端 `pnpm dev` 直接跑源码。首次部署和「部署最新」都需要联网；日常启停可离线。数据库迁移由后端启动时的 Flyway 从源码自动执行，不手工导入 SQL。

> 旧的「离线预编译总包」（586 MB，内含 `payload/app.zip`、`sql/`、apt/`.deb` 运行环境）以及配套的 `unix-deploy.py` / `one-click-deploy.sh` / `restart.sh` / `offline-env.sh` 已全部退役删除，不要混用。

## 三平台入口与引擎

| 平台 | 入口脚本 | 引擎 | 默认安装目录 |
|---|---|---|---|
| windows-x64 | `01-deploy.cmd` / `02-start.cmd` / `03-stop.cmd` / `04-update.cmd` | `myhome-windows.ps1`（PowerShell 5.1） | `%LOCALAPPDATA%\MyHome` |
| macos-arm64 | `01-deploy.sh` / `02-start.sh` / `03-stop.sh` / `04-update.sh` | `myhome-unix.sh`（bash） | `~/Library/Application Support/MyHome` |
| linux-x64 | 同上（`.sh`） | `myhome-unix.sh`（bash） | `~/.local/share/MyHome` |

`myhome-unix.sh` 是 macOS 与 Linux 共用的同一份引擎，靠 `uname -s` 分流（Darwin→期望 arm64，Linux→期望 x86_64），两平台子目录里是同一字节内容。四个 `.sh` 入口只是 `cd` 到自身目录后 `exec bash myhome-unix.sh --action <deploy|start|stop|update> "$@"`；`deploy-now.sh` 供后端「部署最新」按钮分离拉起（setsid→perl→nohup，因 macOS 无 setsid）。

Git 是唯一不内置的工具（无官方独立 unix git 二进制）：引擎检测系统 `git`，缺失时按平台给出安装指引（macOS `xcode-select --install`，Linux `sudo apt-get install -y git`）。Windows 包内附 MinGit。

安装目录可用 `--install-dir DIR`（或环境变量 `MYHOME_INSTALL_DIR`）覆盖；启停、部署最新必须始终用同一目录、同一账号。运行目录布局：`src/{server,web}`、`data/{mysql,files,files-private}`、`state`、`tools`、`logs`。

## 密钥与数据

- Windows：`state` 内数据库口令、密码本密钥、登录密钥、传输盐用 **DPAPI** 保护（绑定原电脑 + 原 Windows 账号）。
- macOS / Linux：无 DPAPI，改用 `0600` 的 `secrets.env` + `0700` 的 `state` 目录权限保护。

三平台都只监听 loopback（后端 8080、私有 MySQL 13306、管理后台 5173 `/admin/`、C 端 5174 `/`），只支持本机访问；不改防火墙、全局环境变量/执行策略或电源设置，不建开机任务。手机、局域网、公网、HTTPS 不在范围内。

必须同时保留 `data`（含私有 MySQL）与整个 `state`。备份前先正常停止应用与数据库。复制目录不等于支持换机恢复（密钥绑定原机/原账号）。

## 初始化口径（三平台一致）

只初始化，不导入测试业务数据：保留大宝/小宝两个账号（初始密码均 `123456`，登录后各自到个人中心修改）、文件分类、菜品分类/做法基础字典、购物车版本状态与迁移历史；相册、图片、视频、文档、菜品、购物车条目、订单、密码本从空开始。重复部署不删已有业务内容、不重置账号密码。不改历史 SQL、不导入旧 `schema.sql`、不伪造 history/baseline、不执行 repair、不跑演示造数脚本。

## 打包

- **`offline-deploy-build/package-master.py`** —— 生成三平台总包 `MyHome-OneClick.zip`（当前交付物）。逐平台校验 `packages.json`（formatVersion=3 / offline=false / runMode=source / platform 匹配）与每个工具链归档的 SHA-256，再按平台编码规则暂存、组装、压缩。**不修改任何源文件**，归一化只发生在暂存副本上。
- `offline-deploy-build/package-oneclick.py` —— 旧的 Windows 单平台打包器（产出 `MyHome-Windows-OneClick-x64.zip`），保留作参考；它会就地改写源文件的 BOM/CRLF，总包一律用 `package-master.py`。

编码规则：Windows `.ps1`/`使用说明.txt`/`执行说明.md` = UTF-8 BOM + CRLF；Windows `.cmd` = CRLF 无 BOM（cmd.exe 遇 BOM 会报错）；`packages.json` = 原字节无 BOM；Unix `.sh`/`执行说明.md`/`packages.json` = LF 无 BOM，`.sh` 带可执行位；`runtime/*` 归档 = ZIP_STORED（本身已压缩，不再二次压缩）。

工具链归档分别存放在工作区根的 `windows-deploy-checks/`、`macos-deploy-checks/`、`linux-deploy-checks/`，由 `package-master.py` 读取核对。

## 失败排查

失败时窗口会显示具体步骤、原因、退出码与日志路径。默认日志目录为安装目录下 `logs/`：首次部署看 `Deploy.log`，启动看 `Start.log`，停止看 `Stop.log`，部署最新看 `Update.log`；服务相关为 `server.log`、`backend.err.log`、`mysql-error.log`、`web-admin.err.log`、`web-h5.err.log` 等。日志创建前的失败以窗口原始错误为准。

缺工具链文件或哈希不符→重新完整复制同版本包；联网失败→确认 GitHub / Maven Central / npm registry 可达后重试；端口冲突→只处理已确认属于自己的程序。不删 `data`/`state`/密钥文件，不清库、不重置 root 认证、不关系统防护来重试。分享日志前检查隐私，不发送 `state`、`secrets.xml`（Windows）、`secrets.env`（Unix）、`mysql-client.ini`/`mysql-client.cnf`、`mysql-init.sql`、`config.json`。

完整命令、成功判据（脚本返回码 + 健康检查 + 浏览器）与平台差异表见 [执行说明.md](执行说明.md)。

## 验证边界

制作环境为 macOS（Apple Silicon）。`myhome-unix.sh` 引擎已在真机 macOS arm64 上功能验证：五件工具链解包 + 探针 + 版本、幂等重装、密钥与传输盐、`runtime.env` 往返、完整 MySQL 生命周期（initialize-insecure → init-file 建库建用户 → SELECT → mysqladmin shutdown → 重启后数据仍在）。总包已通过静态校验：43 个成员集合、全成员 CRC、每个工具链归档 SHA-256 与清单一致、各平台文本编码与可执行位、`runtime/` 为 STORED。

**尚未完成**：完整 git clone → `mvn spring-boot:run` → `pnpm dev` 链路、Linux x64 真机、Windows 真机（PowerShell 5.1 / UAC / DPAPI / NTFS / MySQL 8.4）的原生全流程验收。macOS 隔离回归不能证明 Linux 的 apt/systemd 与 Windows 原生执行可用。本版不能标为已完成三平台原生全流程验收。
