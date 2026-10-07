# 集成测试（批次 B）

本目录当前**没有任何可自动运行的集成测试**。批次 A 红线：

- 不访问任何生产 Mastodon 实例；
- 不执行任何 DDL（包括 `setup-ledger` 的账本表）；
- `import` / `verify` / `rollback` 均为占位（退出码 2），不存在可集成验证的写入路径。

## 批次 B 前置条件

1. **隔离测试实例**：本地或一次性容器内的 Mastodon（版本以目标生产实例为准），提供：
   - `rails runner`（源码部署）或 `docker compose exec`（容器部署）执行入口；
   - 一个本地测试账号；
   - 可丢弃的数据库与媒体存储（绝不允许指向生产库）。
2. **真实微博导出 JSON 样本**：由仓库所有者人工提供到实例侧的受限目录（不入库、不进 fixture）；
   先跑 `weibo_normalize.rb inspect` 重新普查字段，禁止直接套用 `tests/fixtures/field_map.synthetic.yml`。
3. **确认门清单**：见 `../docs/weibo-import.md`（六阶段流程），每个写操作前逐项人工确认。

## 批次 B 计划的集成用例

- `env-check` 在隔离实例上的只读探测（版本/Snowflake 源码/存储模式/账号状态）。
- `setup-ledger` → 试导入 20 条（`--execute` + 确认门）→ `verify` 计数对账 → `rollback` dry-run → 真实回滚 → 复验账本终态。
- 静默回调抑制（`weibo_import/silence.rb`）在隔离实例上逐项审计（见 `../docs/silent-callbacks-audit.md`），
  验证联邦/通知/时间线无副作用泄漏、本地计数与索引完整。
