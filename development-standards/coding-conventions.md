# 编码规范

## 后端规范

### 1. 数据库表规范
- **所有表必须同时有创建时间和更新时间** (关联表/明细表/快照表也不例外)
- **Flyway 迁移版本号必须唯一** (重复版本导致启动失败)
- **重命名表后避免重复添加已存在字段** (V303 重命名后 ADD COLUMN 需检查 V302)
- **服务端禁用 @TableField(fill=...)** (没注册 MetaObjectHandler, MP 会把该列写 NULL 撞 NOT NULL)

### 2. 接口设计规范
- **C/B 端路径分层**: `/api/c/**` vs `/api/b/**`, 不是代码分层
- **去留判据**: B 端有无调用方
- **复用实现**: 同一 service, 不同响应裁剪
- **错误码统一**: 400 (客户端错误), 401 (未登录), 403 (无权限), 404 (不存在), 405 (方法不允许), 409 (冲突)

### 3. 认证与授权
- **会话令牌**: HMAC-SHA256 Bearer Token (7天有效期)
- **拦截器**: 逐请求验签 + 验有效期
- **X-User-Id 整条下线**: 无任何回退
- **ADMIN 无私人读例外**: 跨区裸 ID 404

### 4. 数据传输
- **口令传输**: AES-GCM 加盐加密 (PBKDF2-HMAC-SHA256, 10万轮)
- **五处出入口**: B/C 登录、个人中心改口令、密码本新建/编辑
- **反方向**: 只有密码本 reveal 需要解密
- **硬约束**: https/localhost (Web Crypto API 要求)

### 5. 日志规范
- **prod 日志保留 7 天**: logback rolling policy (max-history=7 + clean-history-on-start=true)
- **明文与哈希都不进日志**: PBEKeySpec 用完 clearPassword()
- **盐本身不进日志**: 启动日志只打"就绪 + 算法"

## 前端规范

### 1. React 规范
- **避免 && 渲染数字类型布尔字段**: 防止 0 被直接显示
- **可选链访问嵌套数组前需完整空值检查**: `data?.list.map()` 会返回 undefined
- **antd v6 Form.List 在共用 FormModal 里回填不上初值**: 改用组件 useState

### 2. antd 组件使用
- **Menu 需用受控 openKeys**: 避免路由变化时自动收起
- **配合 onOpenChange 回调**: 否则点击一级菜单无响应
- **Select 脚本操作 DOM**: 无 .ant-select-selector, 对 .ant-select-content 派发事件开下拉
- **dropdownRender 在 antd 6 已废弃**: 用 popupRender

### 3. UI 设计原则
- **前端校验前移**: 非法选项要在前端就置灰/不展示
- **弹窗/表单无解释性文案**: 用结构差异代替灰字解释
- **弹窗标题只放固定名词**: 元信息放正文
- **复用平台通用样式**: 弹窗内表格也要一致

### 4. C 端零组件库原则
- **h5 用原生 `<video>`**: 不引 xgplayer (保持零构建耦合)
- **shared 导出子路径**: 给 shared 加导出子路径必须重启 dev server
- **playUrl 根相对**: h5 base `/` + vite proxy `/api`→:8080

## Git 规范

### 1. 分支管理
- **远端分支存在性用 git ls-remote 判断**: git branch -a 只反映本地 refs
- **prefer creating new commits**: 而非 amend (除非用户明确要求)

### 2. 提交规范
- **commit message 简洁明了**: 聚焦 "why" 而非 "what"
- **不提交敏感文件**: .env, credentials.json 等

## 测试规范

### 1. 验收标准
- **每次代码修改后必须用浏览器实际测试**: 不能仅靠 curl 验证后端接口
- **验收时别用 class 直接抓弹窗/气泡确认框**: 隐藏标签页离开动画不结束, 残留实例会导致误点误删

### 2. 故障排查
- **环境问题优先改我这侧**: 别让用户动 IntelliJ 配置
- **端口/启动参数冲突宁可我重启 5 分钟**: 也不让用户翻 Run Configuration

---

*最后更新: 2026-09-23*
