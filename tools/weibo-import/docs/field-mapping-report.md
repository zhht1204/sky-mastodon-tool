# 字段映射报告（field-mapping-report）

> `weibo_normalize.rb inspect` 生成普查草稿（默认写 `docs/field-mapping-report.generated.md`，已 gitignore）；
> 本文档说明草稿各列怎么读、怎么填进 `config/field_map.yml`。**映射表是唯一事实来源，禁止凭想象写字段名。**

## 1. 流程

```
真实导出.json ──inspect──► 普查草稿 ──人工逐字段核对──► 映射草稿.yml ──map --from──► config/field_map.yml（gitignored）──► normalize
```

```powershell
ruby install/script/weibo_normalize.rb inspect --input <真实导出.json> --sample 20 --report-out tmp/field-report.md
# 人工填写草稿（复制 config/field_map.example.yml 起稿）
ruby install/script/weibo_normalize.rb map --from <草稿.yml> --out config/field_map.yml
```

## 2. 普查草稿怎么读

| 列 | 含义 | 填映射时的用法 |
|---|---|---|
| 字段路径 | 点路径；`[]` 表示数组元素内部 | 直接抄进各 `field:`；`records_root` 用包装对象节的候选根 |
| 出现率 | 含该字段的抽样记录占比 | 出现率 100% 的字段适合做 id/created_at/text；低出现率字段确认是否可选 |
| 类型分布 | 该路径的值类型计数 | id 若是 Integer 也没关系（全程按字符串处理）；时间字段 String/Integer（epoch）混布要分别验证 |
| 时间样例 ✓ | 样例匹配常见时间形态 | 打 ✓ 的字段才可作 `created_at.field` 候选；确认有无偏移（决定 timezone 是否生效） |
| URL 样例 ✓ | 样例是 http(s) 链接 | source_url / 媒体 url 字段候选 |
| 值样例 | 前 3 个非重复样例（换行显示为 ␤，HTML 已转义） | 人工判断语义（可见性枚举值、转发标记真值集合等） |

另：顶层是包装对象时，报告会列「候选记录根」（数组最大者优先），把该路径填进 `records_root`。

## 3. 逐项填写规范

- `id.field`：必填。取**来源系统唯一 ID**；值全程按字符串处理，JSON 里是整数也不用管。
- `created_at.field` + `timezone`：必填。先看样例有无偏移/是否 epoch：
  - 全部带偏移（含 Z）→ `timezone` 可留空（原偏移优先）。
  - 无偏移的本地时间 → `timezone: "Asia/Shanghai"`（或 `+08:00`）。
  - epoch 秒/毫秒整数 → 直接映射，无需时区。
  - 混布 → 无偏移部分靠 `timezone`，抽查每种形态。
- `text.field` + `html`：必填。样例含 `<br>`/`<a>`/`&amp;` 等则 `html: true`（只做转文本，绝不执行脚本）。
- `source_url.field`：可选但强烈建议（保留原文出处，不丢信息）。
- `visibility`：枚举值从「值样例」抄全；**每个取值都必须**在 `mapping` 声明目标（未声明的取值会让该记录进错误清单）；
  非公开来源配 `strictness`（0..3），映射目标 rank 必须 ≥ strictness（加载时校验，防放宽）。
- `reply.field`：回复目标 ID 字段；空/缺失 = 非回复。
- `repost.field` + `truthy` + `quote_field`：`truthy` 列出导出里表示「是转发」的全部真值（如 `[true, 1, "true", "1"]`）；`quote_field` 是被转发内容摘要。
- `media.list_field` + 子字段：list 必须是数组；子字段名（url/path/alt）按数组元素内部路径填。

## 4. 校验与验证

1. `map --from` 校验内容：必填字段齐全、timezone 形态合法（固定偏移或内置别名）、visibility 映射不放宽、结构合法。**校验不通过的映射不会安装。**
2. 安装后先小样本 `normalize`（如 `--input` 截取前 50 条的副本），核对：
   - 每条契约字段（source/source_id 字符串/created_at 带时区/media/reply/repost/raw_record_sha256）；
   - `errors.jsonl` 为空，或每条错误都是预期中的数据问题（时间异常等）而非映射问题。
3. 常见映射问题症状：
   - 大量「缺少 ID 字段」→ id 路径填错或 records_root 未填。
   - 大量「无法解析时间」→ 时间字段选错，或格式超出宽松解析能力（先人工看原始样例）。
   - 大量「未声明的可见性取值」→ 枚举没抄全（回普查报告「值样例」列补全）。
   - 媒体全空 → list_field 或 url 子字段路径不对（普查报告 `pictures[].url` 一类的路径）。

## 5. 归档与版本

- `config/field_map.yml` 不入库（仓库零数据）；**映射决策依据**（普查报告 + 人工核对结论）建议随批次记录存档于实例侧受限目录。
- 导出工具换版本/换字段名时：重跑 inspect、重新走本流程；不得在旧映射上直接改字段名。
