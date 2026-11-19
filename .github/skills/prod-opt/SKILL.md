---
name: prod-opt
description: "sky-mastodon-tool 生产环境运维标准。MUST USE when 需要连目标 Mastodon 实例的生产库执行只读巡检、微博历史归档导入前的备份与核对、或处理生产凭据（.env.production）时。"
argument-hint: "生产巡检、迁移执行、数据核对或状态检查"
---

# Sky Mastodon Tool 生产运维（prod-opt）

本仓库是 Ruby CLI 工具，不自带数据库与常驻服务：它直接操作**目标 Mastodon 实例**的 PostgreSQL 与媒体存储。所有生产写操作都作用在别人的生产数据上，风险等级最高，务必先备份、先核对、再确认。

## 凭据来源：仓库根目录的 `.env.production`

- 查找顺序：`<项目根>/.env.production` → `<项目根>/tools/.env.production`。
- 该文件**必须被 gitignore**：`git check-ignore -v .env.production` 没有输出就立刻补上，并提醒用户不要提交。
- 只取需要的键，**不要 `cat` 整个文件**（会把密钥打进终端输出）。查看时用掩码：
  `grep -E '^(DATABASE_URL|PROD_SSH_HOST)=' .env.production | sed -E 's#://[^@]*@#://***:***@#'`
- **不猜、不硬编码**：缺少连接信息时让用户补 `.env.production`，不要用开发库连接串顶替，也不要把密码写进仓库文件、提交记录或聊天输出。
- 模板：`../sky-guiding/.github/skills/prod-opt/references/env.production.template`

## 安全红线

> **硬性前提**：`.env.production` 没填好就**停下来问用户**——不要从其它仓库/环境的口令推断，不要尝试任何口令组合，不要对生产地址做端口扫描或凭据试探。生产写操作（哪怕是幂等迁移、哪怕影响很小）必须拿到用户明确授权后再执行；"命令看起来安全"不构成授权。

1. **默认只读**：`SELECT`、容器状态、健康检查、审计查询可以直接做。
2. **写操作先确认**：迁移、`INSERT/UPDATE/DELETE`、DDL、重启容器前，先说明「执行什么 / 影响哪些表与行 / 是否可回滚」，得到用户明确同意再执行。
3. **先看再改**：写操作前先跑对应的 `SELECT` 看清现状与影响行数，把结果贴给用户。
4. **不打印凭据**：命令行用环境变量而不是明文连接串；输出里出现密码时用掩码替换。
5. **一次一条命令、可回滚**：迁移带 `-v ON_ERROR_STOP=1`（或项目自己的迁移命令），失败立刻停下报告，不要"改个字段再跑一遍"糊过去。
6. **临时文件清理**：写在 `/tmp` 或临时目录的中间文件用完删除。
7. **不越界**：只操作本次任务点名的服务与库，不顺手改别的实例。
8. **留痕**：写操作结束后把执行的 SQL 与影响行数写进回复，便于事后追溯。

## 本项目的生产事实

- 形态：Ruby CLI / Rails runner 脚本（`tools/weibo-import/`），无 web 服务、无自有数据库；复用目标实例的 PostgreSQL、Redis 与媒体存储。
- 目标实例：连接信息来自 `.env.production`（`DATABASE_URL` 等），对应目标 Mastodon 实例的库。
- 备份：导入前必须先备份目标表，`tools/weibo-import/install/script/weibo_import/backup.rb` 是现成的备份脚本。
- 演练：`tools/weibo-import/testenv/` 提供一次性本地测试编排（`docker-compose.yml`），用完必须 `teardown.ps1` 销毁；**禁止在生产实例上做首次演练**。
- 仓库零数据：真实微博内容、字段映射与凭据一律不进仓库。

## 连接方式

**方式 A — 直连（psql 可达）**

```bash
export $(grep -E '^DATABASE_URL=' .env.production | xargs)
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -f <migration.sql>
```

**方式 B — 经生产机 + 容器（数据库只对内网开放时）**

`.env.production` 里给 `PROD_SSH_HOST`、`PROD_SSH_USER`、`PROD_PG_CONTAINER`、`PROD_PG_USER`、`PROD_PG_DATABASE`：

```bash
ssh "$PROD_SSH_USER@$PROD_SSH_HOST" "docker exec -i $PROD_PG_CONTAINER psql -U $PROD_PG_USER -d $PROD_PG_DATABASE -v ON_ERROR_STOP=1" < <migration.sql>
```

Windows 本机没有 `psql` 时用 `E:\PostgreSQL\17\bin\psql.exe`，或走方式 B。

## 本项目常用巡检

| 目的 | 手段 |
|---|---|
| 实例连通 | `psql "$DATABASE_URL" -c 'select 1'` |
| 备份可用性 | 导入前先跑备份脚本并确认产物大小与时间戳 |
| 目标表现状 | 先 `SELECT` 统计待导入/已导入行数与边界，再决定是否写入 |
| 导入任务 | 用目标实例的日志与 `shared/` 里的进度文件核对，不凭印象判断 |
| 测试环境 | `tools/weibo-import/testenv/` 用完 `teardown.ps1` 清理，不留常驻容器 |

## 与其它 Skill 的关系

- 通用规则与红线以 `../sky-guiding/.github/skills/prod-opt/SKILL.md` 为准；本文件只补充 sky-mastodon-tool 的专属事实。
- 涉及 SSO 协议语义时以 `../sky-guiding/.docs/SSO_INTEGRATION.md` 与 `../sky-sso/AGENTS.md` 为准。
- 排查具体故障并需要留档时，按本仓库的 `debug-case` Skill 登记案例。
