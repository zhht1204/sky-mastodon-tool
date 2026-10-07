# docker compose exec 用法模板

> 模板中的服务名（`web`）、容器内路径（`/mastodon`）、脚本路径（`$MASTODON_DIR/script/...`）都是**占位符**。
> 必须先按实例实际的 compose 服务名与挂载情况替换并验证，再执行任何命令。

## 0. 先验证环境（不要跳过）

```bash
# 1) 确认服务名：compose 文件里实际跑 rails 的服务（常见 web / sidekiq / app）
docker compose ps

# 2) 确认容器内 Mastodon 目录与 Rails 入口
docker compose exec <服务名> sh -lc 'ls -la /mastodon 2>/dev/null || pwd; which rails bundle 2>/dev/null'

# 3) 验证 rails runner 参数传递（无害只读探针，退出码应为 0）
docker compose exec -T <服务名> sh -lc \
  'cd /mastodon && bin/rails runner "puts \"runner-ok argc=#{ARGV.size} argv=#{ARGV.inspect}\"" -- --probe1 --probe2'
```

注意：`rails runner` 之后传参给脚本时，`--` 与引号嵌套在不同 Mastodon 版本/镜像中行为不一致。
**必须先用上面的无害探针验证参数传递**，确认脚本确实收到完整 ARGV 后，再执行真实命令。

## 1. 环境检查（只读，批次 A 可用）

假设安装树已复制到容器内可见路径（挂载或 `docker compose cp`）：

```bash
docker compose cp tools/weibo-import/install/script <服务名>:/opt/sky/ 2>/dev/null \
  || echo "改用宿主机挂载路径（按实例实际挂载调整）"

docker compose exec -T <服务名> sh -lc \
  'cd /mastodon && bin/rails runner /opt/sky/script/weibo_import.rb env-check --account <你的本地账号>'
```

直接安装（非 Docker）时等价于：

```bash
sudo -u mastodon bash -lc 'cd /srv/mastodon && RAILS_ENV=production bin/rails runner script/weibo_import.rb env-check --account <你的本地账号>'
```

## 2. plan（无 Rails 也可跑，纯分析）

```bash
docker compose exec -T <服务名> sh -lc \
  'cd /mastodon && bin/rails runner /opt/sky/script/weibo_import.rb plan --account <账号> --input /opt/sky/normalized.jsonl --report-file /opt/sky/reports/plan.md'
```

## 3. 占位命令（批次 A 不可用，会以非零码退出）

`import` / `verify` / `rollback` / `setup-ledger` 批次 B 交付；当前执行只会打印
「批次 B 交付，本批次不可用」并以退出码 2 结束，不会触碰实例。

## 提醒

- 所有写操作命令（批次 B 起）都要求显式 `--execute`，并逐项确认；dry-run 是默认。
- 以实际服务名/挂载为准：本文档不维护实例事实，事实在 `env-check` 报告与运维笔记中。
