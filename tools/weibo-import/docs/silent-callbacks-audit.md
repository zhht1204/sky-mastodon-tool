# 静默回调审计清单（silent-callbacks-audit）

> 目的：历史归档导入时**必须抑制**会对实例外部或全局状态产生副作用的回调，
> 同时**必须保留（或补偿）**本地数据完整性相关的副作用。
> 本清单是批次 B `weibo_import/silence.rb` 实装与每次导入前审计的模板。
>
> ## 硬性原则（红线）
> - 只在**本次 rails runner 进程内**做局部抑制（`Module#prepend` / 单例方法替换 / 回调对象跳过），进程退出即失效。
> - **禁止**全局禁用回调（如改模型文件、`skip_callback` 写入部署源码、改实例配置文件）。
> - **禁止**全局清空 Sidekiq 入队（如 `Sidekiq::Queue.new.clear`）——只允许本进程内拦截自己的入队。
> - 每一项在执行前都必须「部署源码核实位置」+「runner 局部抑制策略」两栏都有答案；答案必须来自**部署实例的实测源码**（`env-check` 输出版本与 git commit），不得引用上游 main 假设。
> - 审计结论（抑制方式 + 实测源码位置 + 验证观察）记录在案，随批次归档。

## A. 必须抑制的副作用（导入历史帖不应触发）

| # | 副作用 | 部署源码核实位置（按实测版本填写） | runner 局部抑制策略（批次 B 实装） | 验证观察 |
|---|---|---|---|---|
| A1 | 联邦投递（ActivityPub 分发） | `app/services/activitypub/distribution_worker.rb`、`app/models/concerns/status_thread_concern.rb` 等按 4.6.2 实测路径 | 在本进程内 prepend 拦截 `DistributionWorker.perform_async` / `FanOutOnFeedService` 调用点，仅对导入批次前缀的本地 ID 生效 | Sidekiq 日志无新增 distribute 任务；`outbox` 无新增 |
| A2 | 时间线分发（home/列表扇出） | `app/services/fan_out_on_feed_service.rb` | 同上：仅本进程内拦截对导入 status 的 fan-out；不碰其他进程 | Redis streams/feeds 键无写入 |
| A3 | 提及通知（Mention → Notification） | `app/services/post_status_service.rb`（`process_mentions_service` 调用点）、`app/services/process_mentions_service.rb` | 本进程内跳过 mention 通知创建（或置 silent）；本地 mention 记录可保留 | `notifications` 表无导入来源新增 |
| A4 | 邮件通知 | `app/workers/*mailer*`、`app/services/notification_*` 触发链 | 拦截本进程 mailer 入队 | Sidekiq 队列无 mailer 任务 |
| A5 | Webhook 外发 | `app/models/webhook.rb` / `app/services/webhook_service.rb`（若部署版本存在） | 本进程内禁用与导入事件相关的 webhook 触发；**只按账号/事件粒度**，不动全局开关 | webhook 目标无新请求 |
| A6 | FASP（外部内容生命周期公告） | `app/lib/fasp/*` 或 `app/services/fasp/*`（`env-check` 检测 FASP_* 配置；4.6.2 未必存在，以实测为准） | 若存在：本进程内拦截 FASP 事件上报 | FASP 日志/端点无新事件 |
| A7 | 趋势（Trending）统计 | `app/services/trends/*`、`trend*` 回调 | 本进程内对导入 status 跳过 trend 采样 | trends 表无新增 |
| A8 | 活跃度统计（账号/实例计数副作用） | `Account#last_status_at` 回调、`instance_stats`/`activity` 相关服务 | 本进程内跳过导入触发的活跃度刷新（或导入完成后一次性补偿，见 B4） | 统计快照前后一致 |
| A9 | 搜索索引写入（OpenSearch/ES，若启用） | `app/services/search_service.rb`、` chewy`/索引模型（`env-check.search_enabled` 为 true 时必审） | 本进程内跳过索引入队，导入完成后按 §B6 统一重建/补偿 | 索引文档数不变直至补偿步骤 |

## B. 必须保留或补偿的本地副作用（不能为了静默而丢）

| # | 本地状态 | 保留/补偿要求 | 部署源码核实位置 | 策略 |
|---|---|---|---|---|
| B1 | 本地 URI / URL 生成 | status.uri/url 必须正确生成且唯一 | `Status#local_uri`、`activitypub` 模型关注点 | 不抑制；Snowflake ID 时间位回填历史毫秒，URI 随 ID 天然有序 |
| B2 | conversation 聚合 | 导入的回复/续帖链 conversation_id 正确 | `conversation` 模型与 `Status` 回调 | 不抑制本地 conversation 分配；只抑制其联邦分发部分 |
| B3 | 计数器（reblogs/favourites/replies 计数列） | 历史帖计数为 0 且不自增；不因静默出现 NULL | `account_stat`/`status_stat` 模型 | 保留回调；验证导入后 stat 行存在且为 0 |
| B4 | 账号 last_status_at / 统计基线 | 不得被历史时间弄乱（如变成 2010 年） | `Account` 回调 | 抑制逐条刷新，批次结束后按真实最新帖一次性补偿 |
| B5 | 媒体附件（paperclip/S3 写入） | 必须真实写入存储并挂到 status | `Attachment` 模型与 paperclip 处理器 | 不抑制；媒体文件 sha256 与 fetch-media 清单对账 |
| B6 | 缓存与索引（Redis 缓存、搜索索引） | 可延迟但必须补偿；不得永久缺失 | 缓存失效器 / `search_service` | 导入完成后运行一次目标账号的缓存失效与（若启用）索引回填 |
| B7 | 账本（sky_import_ledgers） | 每段一行，状态机完整 | 本工具 `ledger.rb` DDL | 不抑制（本工具自身的表） |

## C. 审计执行顺序（批次 B 每次导入前）

1. `env-check` 获取部署版本 + git commit + FASP/webhook/搜索开关状态；与上次审计记录 diff，任何变化重新核实受影响行。
2. 逐项填写 A/B 两栏（源码位置写**文件+方法**，抑制策略写**进程内机制**）。
3. 隔离实例上以 `--yes` 演练：观察 Sidekiq 各队列增量、Redis 键增量、日志中外发尝试，应为 0（B 类除外）。
4. 演练通过后，生产导入仍逐项确认（G5/G6 门）。
5. 审计记录（本表填写后的副本 + 观察证据）存档，不回填本模板。

## D. 明确禁止的反模式

- `Sidekiq::Queue.new('default').clear`（全局清队列）。
- 修改部署源码文件加 `skip_callback`（进程外持久化）。
- 直接 `UPDATE statuses SET ...` 绕过模型（丢失 B 类副作用）。
- 用 `RAILS_ENV=production rails console` 手工敲导入（无账本、无确认门、无审计记录）。
