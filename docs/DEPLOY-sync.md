# 云同步部署指引（T19）

> 面向：把 `cloudflare/` 下的同步 Worker 部署到用户自己的 Cloudflare 账号。
> 架构依据：`docs/ARCH-windows-sync.md` §4（存储/接口/路由）。
> 前置：Cloudflare 账号 + 一个可写 DNS 的域名（zone）。

---

## 0. 一句话

新建**独立** Worker `ovimap-sync`（不复用你已有的反代 Worker），绑定 **D1**（索引/rev）+
**R2**（快照），设一个 **Secret `SYNC_TOKEN`**，把路由挂到专属子域 `sync.<你的域名>/*`，
然后在 App「设置 → 云同步 → 同步设置」里粘贴**同一令牌 + 服务器地址**。

---

## 1. 安装 wrangler（只在一台部署机上做一次）

```bash
cd cloudflare
npx wrangler login
```

> `wrangler` 按需通过 `npx` 拉取，**不进 App 的 Flutter 依赖**（架构 §11.3）。

---

## 2. 创建 D1 数据库并建表

```bash
npx wrangler d1 create ovimap-sync
```

命令会输出 `database_id`。把它填进 `cloudflare/wrangler.toml` 的
`[[d1_databases]].database_id`（当前是占位符 `REPLACE_WITH_D1_DATABASE_ID`）。

建表：

```bash
# 线上（--remote）
npx wrangler d1 execute ovimap-sync --remote --file=schema.sql
# 本地开发（--local，可选）
npx wrangler d1 execute ovimap-sync --local --file=schema.sql
```

---

## 3. 创建 R2 存储桶

```bash
npx wrangler r2 bucket create ovimap-snapshots
```

> `wrangler.toml` 已声明 `[[r2_buckets]]`（binding `BUCKET`，bucket `ovimap-snapshots`）。
> 若 bucket 名不同，请同步修改。

---

## 4. 设置同步令牌（Worker Secret）

```bash
# 会提示输入值；这个值就是 App 里要粘贴的「同步令牌」
npx wrangler secret put SYNC_TOKEN
```

> 建议用一段足够长的随机串（例如 `openssl rand -hex 32` 的输出）。
> **不要**把令牌写进 `wrangler.toml` 或任何会入库的文件。

---

## 5. 配置路由（专属子域，推荐）

1. 在 Cloudflare DNS 给域名加一条记录，把 `sync.<你的域名>` 指向该 Worker
   （用 **Workers 路由**即可，无需单独 DNS 记录）。
2. 修改 `cloudflare/wrangler.toml` 的 `routes`：

```toml
routes = [
  { pattern = "sync.你的域名.com/*", zone_name = "你的域名.com" }
]
```

> **为什么用专属子域**：Workers 路由按**最长前缀**匹配，`sync.` 子域不会与你已有的
> 反代 Worker（`你的域名.com/*`）冲突，二者互不影响升级（架构 §4.7 / Q1）。
>
> **只有一个域名且不能加子域**时，退化为路径形式（注意与反代 route 不重叠）：
> ```toml
> routes = [{ pattern = "你的域名.com/sync/*", zone_name = "你的域名.com" }]
> ```

---

## 6. 部署

```bash
cd cloudflare
npx wrangler deploy
```

部署后自测：

```bash
curl -s https://sync.你的域名.com/ping -H "Authorization: Bearer <你的令牌>"
# 期望：{"code":0,"data":{"serverTime":...},"message":"ok"}
# 令牌错误/缺失：HTTP 401 {"code":401,...}
```

---

## 7. 在 App 里配对

**桌面（Windows）**：工具栏 🔄 → 「同步设置」，或 菜单「同步 → 云同步面板」。
**移动端**：设置（⚙）→ 云同步 → 同步设置。

填写：
| 字段 | 值 |
|---|---|
| 设备名 | 如 `电脑-信阳办公室`（用于冲突提示，可自定义） |
| 服务器地址 | `https://sync.你的域名.com` |
| 同步令牌 | 第 4 步的 `SYNC_TOKEN` |

点「保存并测试」→ 面板状态应变为「已同步 / 离线」。

---

## 8. 数据模型速览（排障用）

| 存储 | 内容 |
|---|---|
| D1 `projects` | 每工程 1 行：`project_key`(=collection id)、`rev`、`updated_at`、`last_device_id/name`、`deleted`(软删) |
| D1 `snapshots` | 每版本 1 行：`project_key`、`rev`、`r2_key`、`size`、`label_count`、`device_*`、`created_at` |
| R2 | `snapshots/<project_key>/<rev>.json`（客户端 `collection_<id>.json` 原文），每工程保留最近 **RETENTION=10** 版 |

常用排障 SQL：

```bash
# 看某工程索引
npx wrangler d1 execute ovimap-sync --remote \
  --command "SELECT project_key, rev, updated_at, last_device_name, deleted FROM projects ORDER BY updated_at DESC LIMIT 20;"
# 看某工程版本
npx wrangler d1 execute ovimap-sync --remote \
  --command "SELECT rev, label_count, device_name, created_at FROM snapshots WHERE project_key='<cid>' ORDER BY rev DESC;"
```

---

## 9. 安全与运维

- **鉴权**：所有接口（含 `/ping`）都要 `Authorization: Bearer <SYNC_TOKEN>`；无有效令牌 → 401。
- **乐观并发**：`PUT/DELETE` 带 `baseRev`，仅当 `baseRev == 当前 rev` 才接受并 `rev+1`；
  否则 **409**（含服务端 rev/时间/设备名），由客户端弹冲突框三选一。旧版不带 `baseRev`
  且工程已存在 → **一律 409**（保守不覆盖）。
- **软删除**：删除只置 `deleted=1` 并 `rev+1`；`/history` + `/restore` 可恢复。
- **令牌轮换**：`npx wrangler secret put SYNC_TOKEN` 重新设置后，各设备在设置页更新令牌即可。
- **令牌本机存储（明文，知情说明）**：App 端令牌以**明文**存于本机偏好设置
  （`shared_preferences` 的 `syncToken` 键）——v1「单用户自用 + 零新增依赖」约束下的
  既定取舍。自用设备可接受；**设备丢失/转手请立即轮换 `SYNC_TOKEN`**（上一条）。
  升级为系统安全存储（如 `flutter_secure_storage`）需先松绑依赖约束，属 P2 决策。
- **保留数**：改 `wrangler.toml` 的 `[vars] RETENTION` 后重新 `deploy`。

---

## 10. 待用户在真实环境验证（本机无法替代）

- [ ] `wrangler deploy` 成功、`/ping` 返回 `code:0`（有效令牌）。
- [ ] 无令牌 → 401。
- [ ] 两端（手机 + 电脑）配对同一令牌后：一端保存 → 另一端 30s 内可见。
- [ ] 断网改点 → 联网自动补传（待上传徽标归零）。
- [ ] 两端离线各改同一工程 → 联网弹冲突框；选「另存冲突副本」后云端与原工程**都保留**。
- [ ] R2 中每工程最多保留 10 个 `rev`.

> 备注：本仓库已用**零网络单测**覆盖上述服务端语义（`test/sync_*_test.dart`）与
> Worker 纯逻辑（`cloudflare/test/worker.test.mjs`），但**真实 Cloudflare 环境**
> （D1/R2 绑定、子域路由、令牌 Secret）必须由用户在真机/真账号上跑通。
