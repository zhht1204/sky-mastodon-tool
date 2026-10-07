# tests/fixtures — 测试夹具

全部为**自制合成样本**：字段形态模仿常见微博导出工具，但 ID、URL、正文、账号含义均为编造；
域名一律使用保留域（`example.synthetic`）。**绝不包含真实微博内容、真实账号或任何凭据。**

| 文件 | 用途 |
|---|---|
| `synthetic_all.jsonl` | 主夹具（16 条）：正常单图帖、超长正文、字符串 ID、九图帖、转发（quote 超 200 字素）、回复、epoch 毫秒时间、非法时间、未来时间、早于 2009 时间、缺 URL 媒体、视频混图、缺正文字段、仅自己可见、重复 source_id、UTC 偏移与无时区时间 |
| `synthetic_wrapped.json` | 顶层包装对象（`records_root: data` 探测/展开） |
| `synthetic_array.json` | 顶层 JSON 数组格式 |
| `synthetic_badlines.jsonl` | 中间行故意损坏，测试 JSONL 解析错误清单 |

配套映射模板见 `field_map.synthetic.yml`（与上述夹具字段一一对应；e2e 演练也用它）。
