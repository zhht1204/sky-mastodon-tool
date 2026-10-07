# testenv — 一次性隔离 Mastodon 4.6.2 测试环境

批次 B（importer / verify / rollback / setup-ledger 实装与集成测试）的隔离测试实例。
**绝不用于连接生产实例**；本环境的一切数据都是可丢弃的。

## 隔离保证

| 项 | 值 |
|---|---|
| compose project | `weibo-import-testenv`（独立命名，不与本机其他容器/卷混用） |
| Web 暴露 | 仅 `127.0.0.1:46500`（不监听局域网/公网） |
| LOCAL_DOMAIN | `127.0.0.1:46500`，联邦域名不可解析 → 不会向实例外发送联邦消息 |
| 存储 | S3 关闭，媒体在本地命名卷 `media-data`；`down -v` 即销毁 |
| 搜索 / 通知 | ES 关闭；无真实 SMTP（发信失败仅写日志） |
| 数据库 | 独立 `postgres:16-alpine` 命名卷，与共享开发 PG（192.168.31.20）无关 |
| Redis | 独立 `redis:7-alpine`，关闭持久化 |
| 镜像 | `ghcr.io/mastodon/mastodon:v4.6.2`（与生产标称版本对齐；实际差异仍以 env-check 输出为准） |

## 用法（Windows 开发机，需 Docker）

```powershell
cd tools/weibo-import/testenv
powershell -ExecutionPolicy Bypass -File setup.ps1            # 一键初始化（幂等）
powershell -ExecutionPolicy Bypass -File setup.ps1 -Account importer2
powershell -ExecutionPolicy Bypass -File teardown.ps1         # 销毁容器与全部数据卷
powershell -ExecutionPolicy Bypass -File teardown.ps1 -RemoveEnv  # 连 .env 一起删
```

初始化完成后：

- 实例地址：`http://127.0.0.1:46500`（健康检查 `/health`）
- 本地账号：默认 `importer`（供 `weibo_import.rb --account importer` 使用）
- Rails 入口（批次 B 脚本就位后）：
  ```powershell
  docker compose exec -T web bundle exec rails runner -e production script/weibo_import.rb -- plan --account importer --input /import/normalized.jsonl
  ```
  脚本与输入需先复制进容器可见路径（见 `../../../deploy/compose-usage.md`）。

## 注意

- 本机为共享 Docker 环境：务必在用完后立即 `teardown.ps1`，避免长期占用 2–3 GB 内存与磁盘。
- `.env` 由 `setup.ps1` 生成（含随机密钥），已被仓库 `.gitignore` 忽略。
- 若 `ghcr.io` 拉取缓慢/失败，可为 daemon 配置镜像加速或改用可达的 ghcr 镜像源并同步修改 `docker-compose.yml` 中的 image 前缀。
