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

## 系统后台与运维决策（v32~v56）

### 31. 三档固定角色 RBAC + 可编辑权限勾选矩阵
**决策**: 角色固定三档 `SUPER_ADMIN/ADMIN/MEMBER` 不可增删; 权限项固定 23 码 (`PermissionCatalog`); 可配置的只有「某档勾选了哪些权限」(v48)  
**原因**: 角色与权限项都不让超管在页面上增删, 否则就成了"自己给自己造一把新钥匙"; 可编辑的只有勾选矩阵这一层  
**实现**: 勾选存 `role_permission` 表 (V506, role+permission 联合主键), 超管在「角色管理」页编辑; SUPER_ADMIN 不入库、在 `can()`/`resolve` 短路全有  
**门禁分工**: 写操作逐个 `requirePermission(<mod>.manage)`、系统页逐个 `requirePermission(<page>.access)`; **业务读接口只要登录态、不由 `.view` 在后端拦** (`.view` 只驱动前端菜单/路由 403)  
**前端判据**: 一律 `can(user, code)`, 任何 `role === 'ADMIN'` 的写法对超管都会假

### 32. 单超管不变式 + 账号删除放宽
**决策**: 全系统只能有一个超级管理员 (不可交接/不可提第二人/超管行不可改不可删/不能改自己); 账号删除只挡超管, 普通管理员与成员都可删 (v50)  
**原因**: 超管是硬编码短路的身份, 不是勾选出来的; 放宽删除是用户明确要「只有超管不允许被删除」  
**实现**: `updateRole` 三道护栏 + `delete` 只挡超管; 角色下拉「超级管理员」永久置灰 (非法选项前端就置灰)  
**无需迁移**: 种子链 V500→V506 在全新部署上恰好产出一个超管, 不变式由既有数据天然满足

### 33. 系统后台一级菜单归组
**决策**: 账号/角色/目录/变更记录/部署/日志/操作记录/知识库/后端代码/前端代码/数据库十一项收进「系统后台」一个父菜单 (v47 起, 逐步扩到 11 项)  
**实现**: 纯前端菜单归组 (`sub-system`), 零后端/零迁移/零路由改动; 子项不带图标; 桌面 Sider 与窄屏 Drawer 共用同一份 menu JSX  
**门禁**: 整组只有拿得到相应 `.access` 的角色才出现; 路由仍无条件注册, 无权限者敲 URL 由页面 403 分支拦

### 34. 操作审计 + 单请求 traceId 日志回溯
**决策**: 读写全记 (GET/POST/PUT/DELETE)、区分 B/C 端、前端带页面头 `X-Op-Page` + 后端动作字典、出入参脱敏、可配保留天数 (v45); 每请求一枚 traceId 同时落日志 `[traceId]` 段 + `operation_log.trace_id` + 响应头 `X-Trace-Id`, 系统日志页按 traceId 过滤回溯 (v46)  
**采集架构**: `OperationLogCachingFilter` 包请求/响应 + `OperationLogInterceptor.afterCompletion` 组装 + 单守护线程池异步落库 (队列满即丢, 绝不给业务加延迟)  
**两个关键顺序/边界**: 拦截器注册在 `CurrentUserInterceptor` 之后 (逆序回调才能拿到操作人); multipart/流式响应不缓存 body (OOM 防护)  
**traceId 从 request attribute 取而非 MDC**: 审计异步落库, MDC 不跨线程; `TraceIdFilter` 最高优先级 + `finally` 里 `MDC.remove`  
**日志回溯是 v43「极简无过滤器」的唯一定向例外** (用户明确授权, 只此一个 traceId 过滤器, 纯视图层过滤不碰 tail/offset)

### 35. 系统日志页：目录锚定 + 保留天数驱动 logback
**决策**: 多文件切换 + 实时 tail (~1.5s 轮询增量) + 自动滚底, 无 level/keyword 过滤器 (v43); 保留天数超管可配、默认 7 (v44)  
**目录锚定**: `logging.file.name` 的父目录——部署机由 ps1/unix 引擎注入 `LOGGING_FILE_NAME`, dev 为空则优雅退化空态  
**保留天数单一机制**: 页面值直接驱动 logback `maxHistory`, 不另写 `@Scheduled` 自管清理 (会和 logback 自己的 max-history 打架); 运行期立即生效靠反射改 private `archiveRemover`, 失败降级「下次重启生效」; 持久化 `logs/log-settings.json` + 启动回放

### 36. 部署管理：分离 launcher + 进度文件跨重启接续
**决策**: 「部署最新」的后端正是要被 `taskkill` 重启的那个, 故后端只「分离拉起 `FH_DEPLOY_LAUNCHER` + 读 `FH_DEPLOY_PROGRESS_FILE`」, 绝不自己改代码/杀进程 (v41); 部署历史独立成「部署管理」页、变更记录页退回只读 (v42)  
**进度接续**: 进度写 `logs/deploy-status.json` (原子写), 新后端读同一文件、前端轮询无缝续, 重启那几秒显「服务重启中」+ 无限重试  
**历史**: 分离脚本在终态 (done/failed) 头插 `deploy-history.json` (上限 50/按 runId 去重/原子写), 后端只读原样回吐; 点火失败只写 failed 不写历史  
**ps1 必须 `ConvertTo-Json -InputObject`**: 管道会展开单元素数组破坏后端 `isArray()`

### 37. 变更记录：实时优先 + 快照兜底 + 当前运行版本
**决策**: 两仓 commit 走 GitHub 公开 API 循环翻页拉全量 (per_page=100, MAX_PAGES=100 安全阀), 拉不到回退构建期 `change-log.json` 快照 (v39); 每仓标「当前运行版本」(v40)  
**分页/时间/commitId 过滤全在前端这份全量列表上做客户端处理**, 后端不接查询参数  
**runningCommit 只认快照**: 运行中的永远是打包那一刻的 commit, 与列表来源 (live/snapshot) 无关 (v41 起源码直跑改环境变量优先)  
**鉴权**: `requireAdmin` (完整 commit 历史属敏感技术信息); 零新依赖 (JDK HttpClient)

### 38. 在线仓库编辑引擎 RepoService 泛化
**决策**: 知识库/后端代码/前端代码三页共用一个 `RepoService` 引擎——浏览目录树 + 编辑文本白名单文件 + 本地保存 + 一键 `git add/commit/push` (v49 知识库, v51 泛化出代码两页)  
**推送是进程内同步跑**: 不杀后端, 与部署的分离 launcher 本质不同 (部署必须分离是因为 Update 会 taskkill 自身)  
**仓库根目录靠 env 配** (`FH_KNOWLEDGE_REPO_DIR`/`FH_SERVER_REPO_DIR`/`FH_WEB_REPO_DIR`), 未配置优雅降级 `available:false`; 不建表不落库  
**零回归**: v51 把 `KnowledgeService` 改成薄委托, v49 的 controller/api/页面一字未改

### 39. 可视化数据库管理页（全系统权限最高）
**决策**: 表数据行内增删查改 + 结构化改表结构 (含表级说明) + 只读索引清单 + 任意 SQL (读+写+DDL 全放开) + 每日 mysqldump 备份与保留天数 (v52~v56)  
**SQL 全放开的风险兜底**: 前端二次确认 (写/DDL 弹确认框) + 仅超管门禁 (`database.access`, 第 23 码); 能跑任意 SQL 的人本就能跑任意 DDL, 故 DDL 表单只是便利不是安全边界  
**结构化路杜绝注入**: 标识符逐个 `^[A-Za-z0-9_]+$` 校验 + 反引号包裹, 值一律 `PreparedStatement` 占位符; 表说明值走 `quoteLiteral` 转义  
**备份凭据安全**: 写进用完即删 (finally) 的 0600 临时选项文件, 绝不拼进命令行 (命令行在进程列表对所有本地用户可见)  
**备份目录锚定**: `logging.file.name` 祖父目录/backups; dev 无日志文件则备份能力优雅退化, 浏览/改数据/跑 SQL 照常  
**索引只读**: `SHOW INDEX` 按 Key_name 聚合 (LinkedHashMap 保序), 前缀索引标 `列名(长度)`、函数索引显示 Expression; 改索引请到 SQL 页

### 40. 多目录存储与目录管理
**决策**: B 端家庭域「目录管理」仅超管可见, 登记服务器目录 + 切换默认上传 + 目录占用统计 (v36~v38)  
**不可变路径**: V110 `file_storage_directory` 存不可变路径/磁盘身份/默认选择; 旧 key 固定目录 1, 新目录 key 带 `_storage/{id}/`; 旧环境变量不能重新解释历史路径, 掉盘不自动回退  
**新增目录走服务器目录选择** (非访问者本机原生文件窗口), 只选已有空目录、不新增 mkdir  
**公开 `/files/**` 必须反代 Java 多目录解析**, 不能单根 alias

### 41. 三平台联网源码直跑部署总包
**决策**: 交付物一个总包 `MyHome-OneClick.zip`, 含 windows-x64/macos-arm64/linux-x64 三平台 + 一份共享执行说明; 模型是联网·源码直跑 (工具链随包核哈希, 源码部署时按 `packages.json` 联网克隆, `mvn spring-boot:run`/`pnpm dev` 直跑) (v53)  
**共享 bash 引擎** `common/myhome-unix.sh` 靠 `uname` 分流; ⚠️ 所有日志/消息必须走 stderr, 否则污染 `$(func)` 捕获的返回值  
**Git 用系统的** (无官方独立 unix git 二进制), 缺失时按平台给安装指引  
**旧离线预编译总包与 unix-deploy.py 流水线已退役删除**

### 42. 部署模型翻转回「产物直跑」+ Topology A 单端口 (推翻 41 的源码直跑)
**决策**: 用户明确「希望通过运行前后端打的包来运行, 而不是 git pull」, v53 的联网·源码直跑整体翻转回产物直跑 (v57); 交付物仍是三平台总包 `MyHome-OneClick.zip`, 但内置预编译产物 (`build-payload.py` 出 `MyHome-app-payload.zip` = fat JAR + admin/h5 两个 dist + `schema-snapshot.sql` + `version.json`), 部署即解包 `app/` 后 `java -jar`, **全程无 git/mvn/pnpm/node, 首次部署即可离线**  
**运行拓扑 = Topology A**: Spring Boot :8080 同源 serve `/admin/`(B 端) 与 `/`(C 端), 无反代; 运行时只剩后端 JAR + MySQL, 端口从四个 (5173/5174/8080/13306) 收敛到两个 (8080/13306), 旧 dev 端口退役  
**工具链精简到运行必需**: 只留 JDK 21 + MySQL(+Windows VC++), 移除 Maven/pnpm/Node/Git 及全部克隆逻辑  
**升级通道 = GitHub Release 下载**: 发版把产物包传 Releases, 「部署管理」页「部署最新」查最新 release → 下载 → 校验 SHA-256 → 原子换 `app/`(app.new 暂存对调, 旧留 app.old) → 重启; **哈希通过前绝不碰 app/**; latest-asset URL `/releases/latest/download/<asset>` public 仓无需 token, 未发 release 时 404 优雅降级  
**空库冷启动靠 schema 快照**: Flyway 严格版本序回放在 V103 (文件域引用未建的 album/recipe 表) 崩, 故 `family_home` 零表时先加载随包 `schema-snapshot.sql`(`gen-schema-snapshot.py` 真库跑完迁移后 mysqldump, **含真实 Flyway 历史, 绝不伪造/baseline/repair**) 再启后端 → Flyway no-op; 「部署包的 SQL」= 迁移随 fat JAR 走 classpath, 重打 JAR 即带上  
**`packages.json` formatVersion=4 / runMode="artifact"**: 引擎 `assert_artifact_install` 拒接管旧源码/离线安装; `package-master.py` 的 `staged_manifest_bytes()` 把 `app.hash`/`app.version` 改写成实际 payload 值让本地校验对上  
**传输盐固定公开值** `7524e9f1924f761b06c6aad30d767874` (构建期烘进两 dist + 后端同值, 非访问控制/非每装机随机)  
**验证边界**: macOS-arm64 引擎真机功能验证 + 总包静态校验过; Windows/Linux 真机、真实 release 端到端升级、部署机空库冷启动均未跑

---

*最后更新: 2026-10-22*
