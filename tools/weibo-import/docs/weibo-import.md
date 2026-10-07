# weibo-import 操作手册（微博 JSON → Mastodon 历史归档导入）

> 本手册是 weibo-import 的**唯一操作入口**。批次 A 已交付只读阶段（inspect / map / normalize / fetch-media / plan / env-check）；
> 写入阶段（import / verify / rollback / setup-ledger / silence）为占位，批次 B 交付后按本手册执行。
>
> 实例事实以 `env-check` 实测为准；标称版本 4.6.2 仅为假设，不得作为依据。

## 0. 红线清单（每条都是硬约束，违反任何一条即停止操作）

1. **未经本手册定义的确认门，不得对生产实例做任何写入。** 写命令一律默认 dry-run，必须显式 `--execute` 且逐项人工确认。
2. **不访问任何生产实例做开发验证**：写入逻辑只在隔离测试实例上验证（批次 B 前置条件）。
3. **不执行任何 DDL**（包括账本表 `sky_import_ledgers`），除非 `setup-ledger` 在批次 B 经人工确认后幂等创建。
4. **时间保真**：绝不修改来源时间；无法解析 / 未来 / 早于 2009 的时间进错误清单，**绝不用当前时间顶替**，必须人工复核。
5. **可见性只能收紧不能放宽**；导入默认 `unlisted`；映射文件校验会拒绝任何放宽（`visibility.strictness`）。
6. **绝不为了排序人为增减 `created_at`**；Snowflake ID 分配的时间位钳制只动 ID，不动 `created_at`。
7. **不伪造内容**：拆分不自动添加编号/前缀文字；转发以文字引用形式导入（不得伪造为原创）。
8. **静默回调只做局部抑制**（当前 rails runner 进程内），禁止全局禁用回调、禁止全局清空 Sidekiq 入队、禁止改实例配置文件（见 `silent-callbacks-audit.md`）。
9. **仓库零数据**：真实导出 JSON、媒体、备份、密钥、`config/field_map.yml` 一律不入库；测试 fixture 只用合成数据。
10. **回滚只删本工具创建的内容**，不删他人内容；注意 RemoveStatusService 的联邦删除副作用（见 §7）。
11. 每一步写操作前后都要有**账本与计数基线**，最终对账以账本为准（见 §8）。
12. 运行侧脚本只依赖 Ruby 标准库，**绝不向实例引入新 gem**。

## 1. 六阶段流程与确认门

```
阶段1 取样映射 ──► 阶段2 规范化 ──► 阶段3 预演对账 ──► 阶段4 环境与备份 ──► 阶段5 试导入验收 ──► 阶段6 全量导入与收尾
   (只读)          (只读)           (只读)            (只读+实例备份)        (写入·隔离20条)        (写入·生产·批次B/C)
```

每个阶段出口都有一个**确认门**：门未过，下一阶段的写命令不得执行。

| 门 | 通过条件（全部满足才算过） | 责任人签认 |
|---|---|---|
| G1 映射确认 | `inspect` 普查报告逐字段人工核对完毕；`field_map.yml` 通过 `map` 校验安装；字段名禁止凭想象假设 | 人工 |
| G2 数据确认 | `normalize` 错误清单为空，或每条错误均已人工复核并给出处置决定（跳过/修源/改映射）；raw 副本 sha256 抽查一致 | 人工 |
| G3 预演确认 | `plan` 报告数字与手工抽样一致（总数/重复/最早最晚/原创转发回复/非公开/超长/媒体缺失/拆分后帖子数）；异常清单每条策略已确认 | 人工 |
| G4 环境确认 | `env-check` 实测通过：版本/Snowflake 源码位置/存储模式/账号状态无未处置告警；**完整备份已完成并验证可恢复**（pg_dump + 媒体 + .env/密钥 + 账号基线快照） | 人工 |
| G5 试导入验收 | 隔离实例试导入 20 条全量验收清单通过（见 §6）；`verify` 对账零差异；回滚演练通过 | 人工 |
| G6 全量放行 | 批次 C：账本断点策略、失败重试策略、回滚预案、观测窗口（Sidekiq 队列/日志/联邦错误率）全部就绪 | 人工 |

## 2. 命令模板（两套，服务名/路径必须按实例实际值替换）

> **占位符清单**：`<服务名>`（compose 里跑 rails 的服务，常见 `web`/`sidekiq`/`app`）、
> `/mastodon`（容器内 Mastodon 目录）、`/opt/sky`（脚本安装目录）、`<本地账号>`、`RAILS_ENV`。
> 先跑 `deploy/compose-usage.md` §0 的无害探针验证参数传递，再执行真实命令。

### 2.1 docker compose exec（容器部署）

```bash
# 只读阶段（开发机即可，无需实例）：inspect / map / normalize / fetch-media / plan
# —— 在仓库 tools/weibo-import 下执行，输出进 gitignored 的 tmp/ ——

# env-check（必须在实例 Rails 环境跑）
docker compose exec -T <服务名> sh -lc \
  'cd /mastodon && RAILS_ENV=production bin/rails runner /opt/sky/script/weibo_import.rb env-check --account <本地账号>'

# plan（在实例上读 normalized.jsonl；文件先经挂载或 docker compose cp 放入 /opt/sky/）
docker compose exec -T <服务名> sh -lc \
  'cd /mastodon && bin/rails runner /opt/sky/script/weibo_import.rb plan --account <本地账号> --input /opt/sky/normalized.jsonl --report-file /opt/sky/reports/plan.md'

# 批次 B 写命令统一形态（当前为占位，退出码 2）：
docker compose exec -T <服务名> sh -lc \
  'cd /mastodon && RAILS_ENV=production bin/rails runner /opt/sky/script/weibo_import.rb import --account <本地账号> --input /opt/sky/normalized.jsonl --batch B001 --execute'
```

### 2.2 rails runner（源码部署）

```bash
sudo -u mastodon bash -lc 'cd /srv/mastodon && RAILS_ENV=production bin/rails runner script/weibo_import.rb env-check --account <本地账号>'

# plan（无 Rails 依赖，也可直接在开发机跑纯 Ruby）：
sudo -u mastodon bash -lc 'cd /srv/mastodon && bin/rails runner script/weibo_import.rb plan --account <本地账号> --input /opt/sky/normalized.jsonl'

# 批次 B 写命令统一形态（当前为占位）：
sudo -u mastodon bash -lc 'cd /srv/mastodon && RAILS_ENV=production bin/rails runner script/weibo_import.rb import --account <本地账号> --input /opt/sky/normalized.jsonl --batch B001 --execute'
```

### 2.3 开发机纯 Ruby 工具链（不需要实例）

```powershell
ruby install/script/weibo_normalize.rb inspect   --input <导出.json> --sample 20 --report-out tmp/field-report.md
ruby install/script/weibo_normalize.rb map       --from <人工确认后的草稿.yml> --out config/field_map.yml
ruby install/script/weibo_normalize.rb normalize --input <导出.json> --map config/field_map.yml --out tmp/normalized.jsonl --raw-dir tmp/raw_copy/ --errors-out tmp/errors.jsonl
ruby install/script/weibo_normalize.rb fetch-media --input tmp/normalized.jsonl --media-dir media/   # SSRF 安全下载（见 downloader 红线）
ruby install/script/weibo_import.rb plan --account <本地账号> --input tmp/normalized.jsonl --report-file tmp/plan.md
```

## 3. 阶段 1：取样与映射（G1）

1. `inspect --input 真实导出.json --sample 20`（或 `--sample 0` 全量普查），产出字段普查报告（草稿）。
2. 按报告**逐字段人工确认**：id / created_at（含 timezone 与有无偏移）/ text（是否 HTML）/ 媒体数组与子字段 / reply / repost / 可见性映射。
3. 复制 `config/field_map.example.yml` 为草稿填写，`map --from 草稿.yml` 校验并安装到 `config/field_map.yml`（gitignored）。
4. 模板与填法细节见 `field-mapping-report.md`。

## 4. 阶段 2：规范化（G2）

- `normalize`：JSON/JSONL → `normalized.jsonl`；`--raw-dir` 保存只读原始副本（每条一文件 + sha256）。
- 检查 `errors.jsonl`：每条错误**人工复核**（时间异常/缺字段/未声明可见性），处置决定记录在案；绝不用当前时间顶替。
- `fetch-media`（可选）：缺失媒体显式写 `missing-media.jsonl`，绝不悄悄丢弃；下载器拒绝私网/环回/链路本地/云元数据地址，重定向逐跳校验。

## 5. 阶段 3：预演对账（G3）

- `plan --account ... --input normalized.jsonl --report-file ...` 只读产出预演报告。
- **手工抽样核对**：随机抽 ≥5 条来源微博，人工验证：拆分段数、加权长度（URL 计 23）、媒体分组（4 图/帖、视频单帖）、重复与异常标注。
- 报告中"拆分后预计创建帖子数"是 import 阶段 `verify` 的对账基准。

## 6. 阶段 5：试导入 20 条（G5，批次 B）

试导入必须**覆盖以下全部形态**（不足的形态从归档中补选；同一 source_id 不得重复导入）：

| # | 形态 | 要求 |
|---|---|---|
| 1 | 普通短原创（1 图） | 基线：文本/时间/可见性/媒体挂载正确 |
| 2 | 纯文字原创 | 无媒体路径正确 |
| 3 | 超长正文（>500 加权，多段落+句读+URL 混排） | 拆分段数与 plan 一致；段间 reply 链正确；URL 未被切断 |
| 4 | 9 图帖 | 4+4+1 三帖，保序，不丢图 |
| 5 | 视频 + 图片混排 | 视频单独成帖 |
| 6 | 转发（repost） | 以文字引用导入，quote 截断 200 字素 |
| 7 | 回复（reply_to 指向已导入帖） | 段/帖间 reply 关系正确 |
| 8 | 回复（reply_to 指向未导入/外部帖） | 策略：跳过 reply 挂接或按映射降级，须在映射阶段决定 |
| 9 | 无时区时间 | 走 default tz，`extra.source_tz=default+08:00` |
| 10 | 带原偏移时间（含 Z） | 偏移保留，瞬间不漂移 |
| 11 | epoch 毫秒时间 | 解析为 UTC |
| 12 | 每种可见性各 ≥1（public/friends→private/onlyme→direct） | 只紧不松 |
| 13 | 重复 source_id ×2 | 第二条被账本唯一约束跳过 |
| 14 | 缺媒体 URL | 进缺失清单，帖子仍导入并标注 |
| 15 | 错误时间 ×1（非法/未来/早于 2009 各选或择一） | 不导入，错误清单与账本失败态一致 |
| 16 | 空正文仅媒体 | 媒体续帖策略验证 |
| 17 | 含 CJK+emoji 正文 | 字素计数与显示正确 |
| 18 | 含 HTML 正文（若来源是 HTML） | 转文本结果人工核对 |
| 19 | 边界长度正文（恰 500 加权 ±1） | 拆分阈值正确 |
| 20 | 同一毫秒多条 | Snowflake 序列递增、父<子 |

**验收清单（全部通过才过 G5）**：

- [ ] 20 条全部按 plan 预计段数创建，`verify` 计数零差异。
- [ ] 抽查 5 帖：`created_at` 与来源一致（到秒与偏移）、文本无伪造前后缀、可见性符合映射。
- [ ] 媒体：图/视频数量、顺序、alt 与清单一致；缺失媒体有显式记录。
- [ ] `env-check` 报告的副作用项（联邦/通知/时间线/邮件/webhook/FASP/趋势/统计）逐一静默审计通过（见 `silent-callbacks-audit.md`），实例日志确认无外发。
- [ ] 账本状态机正确：planned → imported；重复条目不重复建帖。
- [ ] 回滚演练：dry-run 列表正确 → 真实回滚 → 复验账号计数与基线一致。

## 7. 回滚流程与联邦删除风险（批次 B）

**风险本质**：Mastodon 的 `RemoveStatusService` 会向已知实例广播 `Delete` 活动。历史归档帖一旦被实例联邦过（哪怕只是被远端拉取过），回滚删除**可能触发联邦范围的删除传播**，影响可能超出本账号。

流程：

1. `rollback --batch B001`（默认 dry-run）：按账本列出将删除的 status_id / attachment_id 清单与影响面评估（是否曾被联邦投递、有无远端交互）。
2. 确认门：人工评估联邦删除影响；必要时先在隔离实例验证。
3. `rollback --batch B001 --execute`：**子帖先删、父帖后删**；只删账本登记的、本工具创建的内容；不删任何他人内容。
4. 复验：账号 statuses 计数、媒体存储占用、账本状态 `rolled_back`；与备份时的基线快照对账。
5. 若仅需本地隐藏而非删除：优先考虑直接可见性调整（如改 direct），避免联邦 Delete。

## 8. 最终计数口径（批次 C 对账）

所有数字以**账本（sky_import_ledgers）为准**，双口径对账：

```
来源口径：读取 N ─ 规范化成功 S ─ 错误 E（N = S + E）
导入口径：账本 planned P ─ imported I ─ partial X ─ failed F ─ 跳过重复 D
实例口径：账号 statuses 增量 Δstatus ─ attachments 增量 Δattach ─ 媒体存储增量 Δbytes
```

对账等式与容差：

- `I + X + F + D = P`，且 `P = S`（拆分段计入账本行数，不破坏该等式——按 source_id 去重后对账）。
- `Δstatus = I 的段总数`（每段一帖）；`Δattach = 成功挂载的媒体数`；`Δbytes` 与 fetch-media 清单累加值一致（容差：压缩/元数据差异 <1%）。
- 差异超容差：**停止后续批次**，逐条 diff 账本与实例，未解释的差异按事故处理。
- plan 报告的"拆分后预计创建帖子数"= 阶段 5/6 的预期 Δstatus 基准。

## 9. 已知边界与批次 B 前置条件

- 字符上限/链接加权（500/23）与媒体约束（4 图、1 视频/帖）是**默认假设**，批次 B 必须按 `env-check` 抓取的部署源码与实例配置校准（`MAX_CHARS`、URL 权重、Snowflake 位宽）。
- Snowflake ID 时间位取来源 UTC 毫秒，仅在下一条请求毫秒早于已分配毫秒时钳制时间位（`created_at` 不动），保证父帖 ID < 子帖 ID。
- 隔离测试实例、真实导出样本、确认门签认记录是批次 B 的三个硬前置条件。
