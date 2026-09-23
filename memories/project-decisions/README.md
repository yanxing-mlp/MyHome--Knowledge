# 项目决策记录

## 核心架构决策

### 1. C/B 端接口分层原则
**决策**: "不复用 B 端接口" = 路径分层不是代码分层  
**判据**: B 端有无调用方  
**实现**: `/api/c/**` 独立 controller, 委托同一 service  
**影响**: C 端写接口存在 (上传/下单), 白名单方案降级为纵深防御

### 2. 数据分区隔离策略
**决策**: PUBLIC/PRIVATE 双域隔离, ADMIN 无私人读例外  
**实现**: `DataScope.PUBLIC/PRIVATE` + `DataPartition.forRequest()`  
**约束**: 跨区裸 ID 404, owner 服务端定不由请求指定  
**代价**: scope 是可见性分区, 不是权限边界 (B 端改/删不判属主)

### 3. 会话令牌认证取代 X-User-Id
**决策**: 身份换成服务端签发的 HMAC Bearer token (v15)  
**原因**: X-User-Id 可伪造, 任何人 `curl -H 'X-User-Id: 1'` 就成 ADMIN  
**格式**: `v1.<userId>.<exp>.<HMAC-SHA256>` (TTL 7天)  
**密钥**: `fh.auth.token-secret` (dev 公开, prod 仅环境变量)  
**影响**: 令牌只含 userId+exp 不含 role, 每次请求现查 DB 拿最新角色

### 4. 传输层加盐加密
**决策**: 口令传输 AES-GCM 加盐加密 (v11)  
**原因**: 五处出入口线上只有密文, 明文只存在于两端进程内  
**算法**: PBKDF2-HMAC-SHA256 (10万轮) + AES-256-GCM  
**约束**: https/localhost (Web Crypto API 要求 secure context)  
**代价**: 盐两端成对且随 bundle 公开 (不是访问控制)

### 5. 版本化购物车
**决策**: 共享购物车原子幂等消费 (V317)  
**表结构**: `recipe_cart_state` (固定 id=1, version) + `recipe_cart_checkout`  
**机制**: 所有车读写先持有 state 行锁; 创建订单/加菜与清车同事务  
**并发**: 相同版本同操作同目标返回原结果, 普通下单与加菜互斥

### 6. 预签名短时票据播放视频
**决策**: VideoPlayTicket 6h 签名流 (不复用登录令牌)  
**原因**: `<video src>` 由浏览器直接发 GET, 带不上 Authorization 头  
**格式**: `v1.<id>.<scope>.<ownerId>.<exp>.<sig>` (HMAC-SHA256)  
**密钥**: 复用 `fh.auth.token-secret`, 不新增配置项  
**实现**: `FileSystemResource` 才有 Range/206 (seek/快进必需)

### 7. 关联表驱动分组归属
**决策**: album_image_group_rel 是分组归属的唯一来源  
**原因**: 一张图片可关联多个分组, group_id 单列无法表达  
**迁移**: V207 删掉 album_image.group_id 列  
**查询**: EXISTS / NOT EXISTS ("其他"走 NOT EXISTS)

### 8. 软删 + 物理删组合
**决策**: markDeletedAndPurge (先软删行, 后物理删文件)  
**实现**: `@TableLogic` 软删标记 + 提交后物理删文件  
**保护**: 删除前检查全相册活引用, 保护另一侧共享文件  
**清理**: file/V103 标删无引用的存量文件 (周期清洗)

## 业务口径决策

### 9. 菜品默认封面
**决策**: 没图也给一张 (shared SVG data URI)  
**推翻**: "没图就不渲染/字母占位"  
**覆盖**: B 端封面列/点单统计与 C 端六处全覆盖  
**实现**: `resolveRecipeCover(item.coverUrl)` 统一处理

### 10. 订单状态三档
**决策**: PENDING → COMPLETED/CANCELLED (单向推进)  
**定稿档**: 已完成与已取消都是定稿 (/reopen 已下线)  
**统计**: 排除已取消的单  
**删除**: 只有 B 端能把这两档整单物理删掉 (无软删列, 不碰文件)

### 11. 做法管理行内编辑
**决策**: B 端整页行内编辑 (无编辑弹窗)  
**四种改动**: 改名/加选项/删选项/设必选默认, 共用分组 PUT  
**约束**: 做法不排序, 必选默认挂 rel (V312)  
**拦截**: 两道都在 C 端 (先开详情, 浮层内只强制必选)

### 12. 相册上传分组必选
**决策**: B/C 端同一口径, 未选分组就置灰提交  
**例外**: 入口已定分组时 (两端详情页) 选择器整块不渲染  
**多选**: 一张图片可关联多个分组 (V209)  
**城市**: 单选 (移除 tags 模式, 添加 showSearch)

### 13. 账号管理权限收敛
**决策**: 管理员账号一律不可删 (v9/v10)  
**演进**: 
- v8: 管理员可重置别人口令
- v9: 超管也不能看到/编辑任何人的口令
- v10: 账号管理可设置谁是超管 (只写 role 一列)
**现状**: 昵称/手机号/口令只能本人改 (个人中心), 角色由管理员定

### 14. 概念整体删除
**决策**: 菜品"标签" (V314 删表), 菜谱"类型" (V303 重构), C 端"餐段" (V313 删字典)  
**原则**: 说"删除某概念"就要删到库里 (表/后端/两端 UI/文档一起抹掉)  
**保留**: 历史设计原文只为说明当时为什么那么设计

### 15. 日志保留 7 天
**决策**: prod 日志只保留 7 天 (logback rolling policy)  
**配置**: `max-history=7` + `clean-history-on-start=true`  
**机制**: 每次滚动时自动删掉超过 7 天的归档, 应用重启时也清一次  
**dev**: 没配 logging.file.name, 只打控制台

## 技术选型决策

### 16. antd v6 受控组件
**决策**: Menu 需用受控 openKeys 保持展开  
**配合**: onOpenChange 回调, 否则点击一级菜单无响应  
**Form.List**: 在共用 FormModal 里回填不上初值, 改用组件 useState

### 17. React 19 兼容性
**决策**: h5 别用 antd-mobile 命令式 .show() (React 19 静默不渲染)  
**播放器**: xgplayer 3.0.26 (框架无关 ES module, 官方 React 包停在 2.x)  
**封装**: 手写 ref+effect, src 变化销毁重建

### 18. 前端零组件库原则 (C 端)
**决策**: h5 用原生 `<video>`, 不引 xgplayer  
**原因**: h5 零构建耦合, 原生 controls 已够看/seek/全屏  
**代价**: C 端没有倍速菜单/选集侧栏那套 B 端能力

### 19. MyBatis-Plus FieldFill 禁用
**决策**: 服务端禁用 @TableField(fill=...)  
**原因**: 没注册 MetaObjectHandler, MP 会把该列写 NULL 撞 NOT NULL  
**替代**: 手动 set create_time/update_time

### 20. Flyway 迁移版本号唯一
**决策**: 重复版本导致启动失败  
**冲突**: 重命名表后避免重复添加已存在字段 (V303 重命名后 ADD COLUMN 需检查 V302)

---

*最后更新: 2026-09-23*
