# Changelog

本仓库遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格；版本号遵循语义化版本（SemVer）。

## [1.0.0] - 2026-10-07

首个正式版本。微博 JSON 历史归档 → Mastodon（按部署实测为 4.6.x）完整导入工具链。

### 新增

- **解析与规范化**（`weibo_normalize.rb`，纯 Ruby）：`inspect` 字段普查（不预设任何导出工具字段名）→ 声明式字段映射（模板 `field_map.example.yml`）→ `normalize` 输出 JSONL（字符串 ID 全程、原时区保留、零宽噪声清理、异常时间进错误清单绝不用当前时间顶替）；呈现策略参数 `--interactions/--retweet-media/--card` 固化进记录供审计。
- **媒体下载**（`fetch-media`）：SSRF 防护（拒绝私网/环回/链路本地/云元数据，逐跳校验重定向）、大小/超时/重试限制、内容魔数 MIME 校验、SHA-256 记录、路径穿越防御、缺失媒体显式清单；支持防盗链自定义请求头（`--header` 可重复）。
- **预演**（`plan`）：拆分数/媒体/异常清单预演报告，只读；`--limit N` 语义为 N 条来源微博。
- **导入**（`import`）：Rails 模型级创建（绝不走 PostStatusService）；`created_at` 保真 + 确定性历史 Snowflake ID（同毫秒序列递增、父帖 ID < 子帖、`override_timestamps` 保留显式 ID）；账本表 `(account, source, source_id, segment_no)` 唯一约束 + UPSERT + PG advisory lock；状态创建与账本行同事务；孤儿媒体自动清理；幂等重跑/断点续传（`--resume`）/内容哈希冲突报告。
- **静默回调**：进程内定向抑制 Webhook/FASP 公告/实时活跃度统计，保留 URI 生成、conversation/thread、计数缓存、媒体转码与搜索索引；每次拦截输出运行时审计报告。
- **验证**（`verify`）：按账本逐行核对 created_at 毫秒一致、ID 时间位、媒体顺序、无 Mention/Notification、edited_at 为空、串内回复链、队列快照，PASS/FAIL 退出码。
- **回滚**（`rollback`）：默认 dry-run；子帖先删；只操作账本登记对象；他人新互动（回复/收藏/转发/提及）默认阻止，`--force` 才继续；清理 Conversation 残留并重算 last_status_at；不发送联邦删除。
- **环境检查**（`env-check`）：版本/部署形态/DB/Redis/存储/账号基线只读检查 + Snowflake 源码审计定位。
- **测试环境编排**（`testenv/`）：一次性隔离 Mastodon 容器（独立 compose project、仅绑 127.0.0.1、联邦不可达），一键 setup/teardown。
- 单元测试 139 例全绿；README/操作手册/静默回调审计清单/字段映射报告模板。

[1.0.0]: https://github.com/zhht1204/sky-mastodon-tool/releases/tag/v1.0.0
