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

### 21. 购物车一人一菜一行
**决策**: 同菜不同加购人各占一行, 不再合并 (v22)  
**原因**: 唯一键 `uk_recipe(recipe_id)` 下一道菜全车只有一行, 两人加同一道菜会并进同一行 (qty 被覆盖), 分模块展示时另一个人的份数凭空消失  
**迁移**: `V505` (user 号段) 洗完 NULL 后 `creator_id NOT NULL`, `uk_recipe` → `uk_recipe_creator(recipe_id, creator_id)`  
**为何落 user 域**: 洗数据要读 `app_user` (V500 才建), 从零重建时 V3xx 排在 V500 前面子查询会报错 (与 V504 同理; 第一版误放 recipe/V320 已重编号)  
**服务层**: `setItem` 改量/删行两分支都带 `.eq(creatorId)` 只动本人那一行 (不再是 insert-only), `clearCart` 仍整车清; `reorderOrder` 只回写调用人自己名下的行  
**前端**: h5 `OrderPage` 派生 `myCart` (只收 `creatorId===meId`), 本人行渲染步进器、他人行只读 `×qty`; 车栏 `totalQty` 对整车求和

### 22. 上传/下载图片视频保留原件
**决策**: 前端不再压缩画质, 上传下载一律保留原图原视频 (v23)  
**推翻**: 旧的 `compressImage(file, 2560, 0.85)` 长边降采样 + JPEG 重编码  
**原因**: 唯一损画质的环节在前端那次压缩——后端 `FileStorageWriter.write` 一直逐字落盘, 视频 `writeVideoStream` 从不转码  
**实现**: `compressImage` → `prepareImageForUpload` (shared/src/image/prepare.ts, 删 compress.ts); 白名单命中的 jpeg/png/webp/gif 原样直传 (含 EXIF), 只有 HEIC 等非白名单格式才转全尺寸 quality 1.0 JPEG (不缩放) 以躲过后端 415  
**缩略图**: 后端另存独立的 480px/0.8 JPEG (thumbKey) 只给列表显示, 预览与下载取原图 url  
**覆盖**: 5 处调用点 (admin useAlbumImageUpload/RecipeEditPage/ProfilePage/UserCreateModal + h5 AlbumUploadSheet); EXIF 仍在转码前提取; 服务端零改动、零迁移

### 23. B 端左侧菜单改为公私域驱动
**决策**: 家庭/个人各只显示一套菜单, 一个全局域开关, 不再让公私两套入口在同屏冗余并存 (v24)  
**推翻**: 此前"家庭相册/个人相册两个平级一级项" + "文件/视频/密码本各挂公共·私人子项"  
**核心**: 新增 `packages/admin/src/lib/domain.ts` (`Domain='FAMILY'|'PERSONAL'` + `useDomain()`); 家庭域 8 项 (首页/菜谱/点单/相册/文件/视频/密码本 + ADMIN 账号管理), 个人域只 4 项 (相册/文件/视频/密码本), 首页/菜谱/点单/账号管理无个人版  
**域判定**: URL 为准、localStorage(`admin-domain`) 兜底; 路径能判域的 (`/album`/`/file`/`/video`/`/vault` 及 personal/private 前缀) 由路径定并回写 storage, 域无关页 (`/home`/`/recipe/*`/`/user`/`/profile`) 读 storage 沿用上次域  
**刻意不用 React context**: `AdminLayout`、`CurrentUserBlock`、`DomainSwitch` 各自独立调 `useDomain()` 读同一 location, 三处永不脱钩  
**两个切域入口**: ① 常驻域牌 `components/DomainSwitch.tsx` (侧栏菜单区之上 / 窄屏抽屉顶部, 家庭蓝 `#e6f4ff`·个人紫 `#f9f0ff` + `SwapOutlined`, 整块点一下即切, 收起态退化成图标按钮 + Tooltip); ② 头像下拉 `CurrentUserBlock` (家庭/个人打勾 ── 个人中心/注销)  
**切域跳转**: `switchDomainPath` 跳当前模块的对应档 (家庭相册分组↔个人相册分组等), 无对应档回退落地页 (家庭 `/home`、个人 `/album/personal/groups`); 相册详情 `/album/:groupId` 的 groupId 分域专属, 跨域一律回退分组列表 (不套同一 id 避免 404)  
**默认域**: 登录后默认家庭, `admin-domain` 在 `clearCurrentUser` 时刻意不清故跨注销保留、沿用上次退出的域  
**范围**: 零迁移、后端零改动、路由表与页面组件一行未改; 只动菜单渲染 (`FAMILY_MENU_ITEMS`/`PERSONAL_MENU_ITEMS` + `resolveOpenKeys`) 与切域跳转; 数据隔离口径全部沿用 v14

### 24. 文件与视频分组 (两级页 + 多对多)
**决策**: 「文件管理」「视频管理」从一层平铺列表升级为两级 (分组列表 → 点进看内容), 参照相册 (v25)  
**表结构**: `V108 file_group` (一张表靠必传 `biz_type` = `document`/`video` 区分两类分组) + `V109 file_group_rel` (多对多, 一个文件/视频可属多个分组)  
**与相册的差异**: `file_group_rel.file_id` 指向 `file_object.id` (文档/视频没有独立业务表), 相册 `album_image_group_rel` 指向 `album_image.id`  
**删除口径**: 分组**硬删** (同 `file_category` 字典), 不用 `file_object` 两态 `deleted`、也不做相册三态 `status`——分组没有上下架概念; 名称唯一 = 同 `biz_type` + 同分区, 删后同名可重建  
**⚠️ 级联陷阱**: 两外键都 `ON DELETE CASCADE`, 但删文档/视频时 `file_id` 级联**不触发** (`file_object` 是软删、行还在), 故 `DocumentFileService.delete`/`VideoService.delete` 必须显式硬删关联行  
**未分组**: 上传时分组可选、留空 = 未分组; C 端"未分组"**不做减法** (多对多下各组计数重叠, "总数 − 各组"不成立), 改由一级页常驻一张「全部视频 · 含未分组」卡兜住可达性——后端零改动  
**范围**: B/C 端都做, C 端视频分组只读 (文档不下沉 C 端); 分组管理 (建/改名/删/排序/绑定) 仍只在 B 端; 密码本仍是扁平一级项

### 25. C 端视频放开上传
**决策**: C 端从"只读"改为"能看能传、不能删" (v26)  
**实现**: `POST /api/c/video` 复用 `VideoService.upload`, 零新增 service  
**入口分三档**: 一级分组页可选多个现有分组; 二级具体分组页固定该组 (`fixedGroupId`, 不渲染选择器); `/video/all` 没有上传入口 (未分组不是真分组、无 id 可绑, 同相册「其他」卡不给上传)  
**播放器**: C 端仍用原生 `<video controls autoPlay playsInline>` 直接吃 `playUrl` 那枚 6h 签名票据流, 不引 xgplayer/组件库  
**边界**: 删除与分组管理仍只在 B 端, 私人档隔离同相册

### 26. C 端首页公私域切换 (入口按域收敛)
**决策**: C 端首页支持切换「家庭 / 个人」, 把此前并列的五张平铺卡按域收敛 (v27)  
**推翻**: "家常菜谱/家庭相册/个人相册/家庭视频/个人视频"五卡平铺——同一件事出现两遍  
**收敛后**: 家庭域 4 项 (点餐/相册/视频/密码本), 个人域 3 项 (相册/视频/密码本); **菜谱是家庭共享、无个人版, 只在家庭域出现** (与 B 端菜单同口径)  
**与 B 端的关键差异**: B 端域以 URL 为准 + localStorage 兜底; **C 端首页 URL 就是 `/`、没有 scope 段可派生, 故域只存本机 `h5-domain`** (与 B 端 `admin-domain` 各自独立、不串台); **切域不跳路由**, 刷新后从 localStorage 复原  
**底层零改动**: 7 个 `EntryCode` 一个没删, `PATH_BY_CODE`/`ICON_PATH_BY_CODE` 仍是全量键精确映射 (漏配编译报错), 只是分成两套列表按域渲染; 点相册/视频仍复用既有 `/album`↔`/album/personal` 等路由——零迁移、后端零改动、路由表一行未改

### 27. 密码本 C 端只读透出
**决策**: C 端能列表 + reveal 取回口令, 但**不能新建/编辑/删除** (v28)  
**推翻**: 旧口径"密码本不上 C 端、只有 B 端有入口"  
**后端**: 新增 `VaultCController` (`/api/c/vault/accounts`) 只挂 `GET` 列表 + `POST /{id}/password/reveal`; **没挂写路径 → 打过去 405**; 列表裁成 `VaultAccountClientVO` (只 id/name/account 三列), reveal 直接复用 B 端同一个 `VaultAccountService.reveal`  
**reveal 用 POST 不用 GET**: 它触发一次"取回口令"审计 `log.info`、语义非幂等读, 且避免密文进 access log / 浏览器历史  
**前端**: 明文只进组件 state、**绝不落 localStorage/日志、按需 reveal 不预取**; 解密只准写在 `api/vault.ts` (全站前端加解密第四处文件、第六个出入口), 页面/组件里一行加解密都不许有  
**理由**: "最小实现 + 与现有口径一致"——相册/视频 C 端本就是"能看 (能传) 不能删/改", 密码本连"传"都不给

### 28. C 端切域入口收进头像下拉 + 登录可预选域
**决策**: 首页域牌改**只读**, 切域入口移到右上角头像下拉; 登录页也可预选域 (v29)  
**推翻**: v27 那版"可点域牌按钮 `.fh-home__domain-btn` + 交换箭头"  
**只读域牌**: `<span class="fh-home__domain-badge">` (家庭=蓝、个人=紫、前置人群/单人图标), 不可点、无箭头, 只指示当前在哪一档  
**下拉内容**: 一行被动灰字可见性说明 + 「家庭 / 个人」两档切换 + 分隔线 + 注销 (复用 `useDomain().setDomain`, 点完收起)  
**登录选域**: `LoginPage.tsx` 分段控件默认家庭, 登录成功 `setStoredDomain(domain)` 只写 localStorage 不碰 state, 首页 `useDomain` 挂载时读到

### 29. 两端补域可见性说明
**决策**: 每个切域处都补一句可见性说明 (v30)  
**需求原话**: "bc端都需要加一个说明, 说明家庭里面的东西是家庭成员都能看到的, 个人只有自己能看到"  
**文案分两档**: **整句**「家庭里的东西全家都能看到, 个人里的东西只有你自己能看到。」只出现在 C 端登录页 (域概念第一次被遇到的那一屏, 讲透一次); **短版**「家庭全家可见 · 个人仅自己可见」用在 C 端头像下拉与首页英雄区、B 端域牌 Tooltip 与下拉组标题  
**⚠️ 覆盖旧口径**: v29 "登录页不加任何解释文案"被本条推翻 (用户点名要加说明); 这与"弹窗/表单里不要加解释性说明文案"那条反馈不冲突——那是针对表单字段, 这是域概念本身的第一次解释

### 30. C 端首页与登录页视觉刷新
**决策**: 首页英雄区收成一行品牌位、入口改 2 列无卡图标、删「家庭 Home」大标题 (v31)  
**六项改动**:
- 入口网格 3 列 → **2 列** (`grid-template-columns: repeat(2, minmax(0,1fr))`)
- 有框卡片 → **无卡扁平图标块** (透明底、无边框、64×64 图标 + 下方名称, 去掉副标题与「点击进入」提示)
- 英雄区从"品牌行 + 域牌说明行"两行 → **一行品牌位** (logo + 文字列 + 右上角头像)
- 副标题「我们的小窝」由 `<p>` **升为 `<h1>`** (兼页面 h1); ⚠️ 升级必须显式写 `font-size`/`font-weight`, 否则 UA heading 默认值会赢
- 域牌 + 可见性说明**嵌在副标题下面** (`.fh-home__brand-text` flex column gap 8 + `min-width:0` 让说明能在列内折行), 不单独占一整行
- 删掉首页与登录页的「家庭 Home」大标题 (只剩 B 端侧栏渲染这五个字)

**域牌缩到 53×22**: 用户反馈"家庭这个标签是不是太大了"——20px 高 / 11px 字 / 12px 图标, 因为它跟 14px 的副标题同列, 再大就把副标题压成配角, 而它只是个只读指示; 阴影同步减淡 (小胶囊配重投影会显脏); ⚠️ 头像下拉里的 `.fh-home__menu-domain-icon` 是 16px, 与域牌图标各自独立, 不受影响  
**说明文案抽常量**: `DOMAIN_VISIBILITY_HINT` 由英雄区与头像下拉两处共用, 免得日后改一处忘另一处  
**未动**: `packages/h5/index.html` 的 `<title>` 与 `shared/src/brand/logo.ts` 的 `FH_LOGO_ALT` 里那两处「家庭 Home」是不可见字符串 (后者 B/C 共用), 刻意保留  
**范围**: 纯 CSS + JSX 结构, 零迁移、后端零改动、路由与 `entries.ts` 未动

---

*最后更新: 2026-10-13*
