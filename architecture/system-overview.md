# 系统总览

## 项目定位

**MyHome（家庭 Home）** 是一个面向家庭的综合管理系统，涵盖相册、菜谱、视频、密码本等核心模块，支持多用户协同与数据分区隔离。

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
- **反方向**: 只有密码本 reveal 需要解密
- **硬约束**: https/localhost (Web Crypto API 要求)

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

1. **版本化购物车**: 共享购物车原子幂等消费 (V317 recipe_cart_state/version)
2. **预签名流式播放**: VideoPlayTicket 6h 签名票据 (不复用登录令牌)
3. **FileSystemResource**: HTTP Range/206 支持 (seek/快进必需)
4. **关联表驱动**: album_image_group_rel 是分组归属唯一来源
5. **软删 + 物理删**: markDeletedAndPurge (先软删行, 后物理删文件)

## 已下线概念

- **菜品"标签"** (V314 删表): 菜谱只剩分类 + 做法两个维度
- **菜谱"类型"** (V303 重构): 多对多改为一菜一分组
- **C 端"餐段"标签条** (V313 删字典): 早/午/晚三个标签已删除
- **订单"改回待制作"** (/reopen 已下线): 已完成与已取消都是定稿档
- **X-User-Id 身份头** (v15 堵洞): 换成服务端签发 HMAC Bearer token

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

*最后更新: 2026-09-23*
