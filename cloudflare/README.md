# ovimap-sync（滑洲云图 同步 Worker）

Cloudflare Worker：D1（索引/rev）+ R2（快照）实现工程级乐观并发同步。
**独立 Worker**，不要与你的反代 Worker 合并。

## 快速开始

```bash
cd cloudflare
npx wrangler login

# 1) D1
npx wrangler d1 create ovimap-sync
#    → 把输出的 database_id 填进 wrangler.toml 的 [[d1_databases]].database_id
npx wrangler d1 execute ovimap-sync --remote --file=schema.sql

# 2) R2
npx wrangler r2 bucket create ovimap-snapshots

# 3) 令牌（App 里粘贴同一个值）
npx wrangler secret put SYNC_TOKEN

# 4) 路由：编辑 wrangler.toml 的 routes（专属子域 sync.<你的域名>/*）

# 5) 部署
npx wrangler deploy

# 6) 自测
curl -s https://sync.<你的域名>/ping -H "Authorization: Bearer <令牌>"
```

完整步骤、排障 SQL、验收清单见 **`../docs/DEPLOY-sync.md`**。

## 接口（统一响应 `{code,data,message}`；无令牌 → 401）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/ping` | 连通性探测 |
| GET | `/index?since=<ms>` | 工程索引（比对用） |
| GET | `/project/:id?rev=<n>` | 取最新 / 指定版本快照 |
| PUT | `/project/:id` | 上传（`baseRev` 乐观并发；不匹配 → 409） |
| DELETE | `/project/:id` | 软删除（rev+1） |
| GET | `/project/:id/history` | 版本历史 |
| POST | `/project/:id/restore` | 恢复到某版本（生成新 rev） |

## 纯逻辑单测（无需 Cloudflare 账号）

```bash
node --test cloudflare/test/worker.test.mjs
```

覆盖：`revAccepts`（baseRev==rev 才接受）、`revsToPrune`（保留最近 N 版）、
`parseBearer`、`routeOf`。
