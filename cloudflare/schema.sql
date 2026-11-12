-- 滑洲云图 ovimap 同步后端 —— D1 建表（架构文档 §4.2）
--
-- 执行：npx wrangler d1 execute ovimap-sync --remote --file=schema.sql
-- （本地开发用 --local）

CREATE TABLE IF NOT EXISTS projects (
  project_key      TEXT PRIMARY KEY,       -- = collection id
  name             TEXT NOT NULL DEFAULT '',
  kind             TEXT NOT NULL DEFAULT 'label',
  folder           TEXT NOT NULL DEFAULT '',
  edit_mode        TEXT NOT NULL DEFAULT 'design',
  count            INTEGER NOT NULL DEFAULT 0,
  rev              INTEGER NOT NULL DEFAULT 0,   -- 单调递增，权威版本号
  updated_at       INTEGER NOT NULL DEFAULT 0,   -- 毫秒时间戳
  last_device_id   TEXT NOT NULL DEFAULT '',
  last_device_name TEXT NOT NULL DEFAULT '',
  deleted          INTEGER NOT NULL DEFAULT 0,   -- 软删除：1=已删（可恢复）
  created_at       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS snapshots (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  project_key   TEXT NOT NULL,
  rev           INTEGER NOT NULL,
  r2_key        TEXT NOT NULL,
  size          INTEGER NOT NULL DEFAULT 0,
  label_count   INTEGER NOT NULL DEFAULT 0,
  device_id     TEXT NOT NULL DEFAULT '',
  device_name   TEXT NOT NULL DEFAULT '',
  created_at    INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_snapshots_pk ON snapshots(project_key, rev DESC);
CREATE INDEX IF NOT EXISTS idx_projects_updated ON projects(updated_at DESC);
