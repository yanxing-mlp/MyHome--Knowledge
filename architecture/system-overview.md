# 系统总览

## 架构图

![MyHome Architecture](../assets/architecture-diagram.png)

## 项目定位

**MyHome（家庭 Home）** 是一个面向家庭的综合管理系统，涵盖相册、菜谱、点单、视频、文档、密码本等核心模块，支持多用户协同与数据分区隔离，B 端（admin，antd v6）负责管理、C 端（h5，零组件库）负责日常使用。

## 技术栈

### 后端
- **框架**: Spring Boot 3.5 + Java 21
- **ORM**: MyBatis-Plus
- **数据库迁移**: Flyway
- **数据库**: MySQL 8.0 (utf8mb4_0900_ai_ci)
- **存储**: 本地文件系统 + FileSystemResource (HTTP Range 支持)
- **认证**: HMAC-SHA256 Bearer Token (7天有效期)

### 前端
- **框架**: React 19.3 + TypeScript 5.9.3
- **构建工具**: Vite 8.3
- **包管理**: pnpm monorepo (admin/h5/shared)
- **UI 库**: antd v6 (B端), 原生 HTML (C端)
- **路由**: React Router v6

### 部署
- **日志**: prod 保留 7 天 (logback rolling policy)
- **端口**: 后端 8080, admin 自动递增, h5 自动递增
- **HTTPS**: 传输层加密要求 https/localhost

## 核心架构原则

### 1. 数据分区隔离
- **PUBLIC（公共）**: owner_id = 0, 全家可见
- **PRIVATE（个人）**: owner_id = 当前账号, 仅本人可见
- **ADMIN 无例外**: 管理员不能绕过私人隔离
- **跨区裸 ID 404**: 防止枚举攻击

### 2. C/B 端接口分层
- **路径分层**: `/api/c/**` vs `/api/b/**`, 不是代码分层
- **去留判据**: B 端有无调用方
- **复用实现**: 同一 service, 不同响应裁剪

### 3. 会话令牌认证
- **格式**: `v1.<userId>.<exp>.<HMAC-SHA256>`
- **密钥**: `fh.auth.token-secret` (dev 公开, prod 环境变量)
- **拦截器**: 逐请求验签 + 验 7 天有效期
- **X-User-Id 整条下线**: 无任何回退

### 4. 传输层加密
- **口令传输**: AES-GCM 加盐加密 (PBKDF2-HMAC-SHA256, 10万轮)
- **五处出入口**: B/C 登录、个人中心改口令、密码本新建/编辑
- **反方向**: 只有密码本 reveal 需要解密 (前端解密共四处文件六出入口, 只准写在 api 层)
- **硬约束**: https/localhost (Web Crypto API 要求)

### 5. 公私域 (Domain) 驱动的两端导航
- **概念**: `Domain = 'FAMILY' | 'PERSONAL'`, B/C 两端各一套菜单/入口按域收敛, 不再让公私两套入口同屏冗余并存
- **B 端** (v24): `lib/domain.ts` + `useDomain()`; 域**以 URL 为准** + `localStorage('admin-domain')` 兜底; 刻意不用 React context (三处独立读同一 location, 永不脱钩); 切域跳当前模块对应档, 无对应档回退落地页
- **C 端** (v27/v29): 首页 URL 就是 `/`、**没有 scope 段可派生**, 故域**只存本机 `h5-domain`**; **切域不跳路由**, 只换首页展示的入口; 切域入口在头像下拉, 域牌只读; 登录页可预选域
- **可见性说明** (v30): 整句版只在 C 端登录页 (域概念第一次被遇到的那一屏讲透一次), 短版「家庭全家可见 · 个人仅自己可见」用在两端切域处; C 端抽成常量 `DOMAIN_VISIBILITY_HINT` 两处共用
- **域无关模块**: 首页/菜谱/点单/账号管理无个人版; 菜谱是家庭共享, 只在家庭域出现

## 模块边界

| 模块 | Maven artifactId | 职责 |
|------|------------------|------|
| fh-common | fh-common | Result/PageResult/异常/错误码/三态枚举/SessionToken/TransportCipher |
| fh-boot | fh-boot | 启动类/配置/静态映射/异常处理/health |
| fh-module-album | fh-module-album-biz | 相册分组/图片/城市分布/上下架 |
| fh-module-recipe | fh-module-recipe-biz | 菜谱/分类/做法/购物车/订单 |
| fh-module-file | fh-module-file-biz | 文件上传/下载/分类/文档/视频 |
| fh-module-vault | fh-module-vault-biz | 密码本/账号保管 |
| fh-module-user | fh-module-user-biz | 账号管理/登录/个人中心 |

## 关键特性

1. **版本化购物车**: 共享购物车原子幂等消费 (V317 recipe_cart_state/version); 一人一菜一行 (V505 uk_recipe_creator, 同菜不同加购人各占一行)
2. **预签名流式播放**: VideoPlayTicket 6h 签名票据 (不复用登录令牌)
3. **FileSystemResource**: HTTP Range/206 支持 (seek/快进必需)
4. **关联表驱动**: album_image_group_rel 是分组归属唯一来源; file_group_rel 同理管文档/视频分组 (V108/V109)
5. **软删 + 物理删**: markDeletedAndPurge (先软删行, 后物理删文件); 分组类字典 (file_category/file_group) 是硬删
6. **保留原件**: 前端不压缩画质 (`prepareImageForUpload` 白名单原图直传, 仅 HEIC 转全尺寸 JPEG); 后端另存独立 480px 显示缩略图, 视频从不转码

## C 端能力边界 (与 B 端逐档对比)

| 模块 | C 端 (h5) | B 端 (admin) |
|------|-----------|--------------|
| 相册 | 看在架图/组 + 上传 (必选现有分组, 不给新建) | 全量管理 + 建组/上下架/排序/删除 |
| 视频 | 看 + **上传** (v26 起; 一级可选多组/二级固定组/「全部」页无入口) | 全量管理 + 分组管理 + 删除 |
| 密码本 | **纯只读** (v28 起: 列表 + reveal 取回口令, 写路径 405) | 新建/编辑/删除/reveal |
| 文档 (文件管理) | **不下沉 C 端** | 全量管理 + 分组 |
| 菜谱/点单 | 点餐 + 购物车 + 订单 (家庭域专属) | 菜谱/分类/做法/点单管理/统计 |
| 账号 | 无个人中心、无切换账号, 注销只清本机身份 | 个人中心 (改昵称/手机号/口令/头像) + ADMIN 账号管理 |

**共同边界**: C 端"能看 (能传) 不能删/改管理"; 删除与管理动作一律留 B 端。

## 已下线概念

- **菜品"标签"** (V314 删表): 菜谱只剩分类 + 做法两个维度
- **菜谱"类型"** (V303 重构): 多对多改为一菜一分组
- **C 端"餐段"标签条** (V313 删字典): 早/午/晚三个标签已删除
- **订单"改回待制作"** (/reopen 已下线): 已完成与已取消都是定稿档
- **X-User-Id 身份头** (v15 堵洞): 换成服务端签发 HMAC Bearer token
- **B 端公私两套平级一级菜单** (v24): 改由公私域驱动, 每域一套菜单
- **C 端首页五张平铺卡** (v27): 按域收敛成家庭 4 项 / 个人 3 项
- **C 端首页可点域牌按钮 + 交换箭头** (v29): 域牌改只读, 切域入口移进头像下拉
- **C 端「家庭 Home」大标题** (v31): 首页与登录页都删掉, 只剩副标题「我们的小窝」升为 h1; 这五个字此后只有 B 端侧栏渲染

## 风险与边界

### 风险 1: 静态文件 URL 不鉴权
- 视频走签名票据故不受影响
- 图片/文档静态 URL 仍可直接访问

### 风险 14: scope 是可见性分区, 不是权限边界
- B 端只做到"列出来只有自己的"
- 改/删/绑与图片分页吃的是裸 id, 一律不判属主
- C 端四处全堵 (服务端 gate)

### 边界: 传输层加密 ≠ 访问控制
- 盐两端成对且随 bundle 公开
- 换来的硬约束是 https/localhost
- 存储层哈希/加密未改动

---

*最后更新: 2026-10-13*
