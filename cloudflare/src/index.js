/**
 * 滑洲云图 ovimap — Cloudflare Worker 同步后端（架构文档 §4）。
 *
 * 存储：D1 存索引/rev/版本元数据（`projects` + `snapshots`），R2 存每版本快照原文
 * （`snapshots/<id>/<rev>.json`）。每工程保留最近 RETENTION（默认 10）版。
 *
 * 鉴权：单用户共享 Worker Secret `SYNC_TOKEN`（`Authorization: Bearer <token>`）；
 * 无有效令牌 → 401。不做账号体系。
 *
 * 统一响应：`{ "code": 0, "data": {...}, "message": "ok" }`；
 * 乐观并发：`PUT/DELETE` 带 `baseRev`，`baseRev != 当前 rev` → 409。
 */

// ===================== 纯函数（可被 node --test 直接单测） =====================

/** 乐观并发判定：仅当 baseRev 非空且等于当前 rev 才接受（缺失一律不匹配，保守不覆盖）。 */
export function revAccepts(baseRev, currentRev) {
  return baseRev !== null && baseRev !== undefined && Number(baseRev) === Number(currentRev);
}

/** 快照保留：保留最近 keep 个 rev，返回**应删除**的 rev（升序）。 */
export function revsToPrune(revs, keep) {
  const sorted = [...revs].map(Number).sort((a, b) => a - b);
  if (!(keep > 0)) return sorted;
  if (sorted.length <= keep) return [];
  return sorted.slice(0, sorted.length - keep);
}

/** 从 Authorization 头解析令牌（支持 `Bearer x` / 裸 `x`）。 */
export function parseBearer(header) {
  const h = (header || '').trim();
  if (!h) return '';
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return (m ? m[1] : h).trim();
}

/** 路由解析：method + pathname → 命中的路由与参数（null=未命中）。 */
export function routeOf(method, pathname) {
  const seg = pathname.split('/').filter((s) => s.length > 0);
  const m = method.toUpperCase();
  if (seg.length === 1 && seg[0] === 'ping' && m === 'GET') return { name: 'ping' };
  if (seg.length === 1 && seg[0] === 'index' && m === 'GET') return { name: 'index' };
  if (seg.length === 2 && seg[0] === 'project') {
    const id = decodeURIComponent(seg[1]);
    if (m === 'GET') return { name: 'projectGet', id };
    if (m === 'PUT') return { name: 'projectPut', id };
    if (m === 'DELETE') return { name: 'projectDelete', id };
  }
  if (seg.length === 3 && seg[0] === 'project') {
    const id = decodeURIComponent(seg[1]);
    if (seg[2] === 'history' && m === 'GET') return { name: 'history', id };
    if (seg[2] === 'restore' && m === 'POST') return { name: 'restore', id };
  }
  return null;
}

// ===================== 工具 =====================

const JSON_HEADERS = { 'Content-Type': 'application/json; charset=utf-8' };

function resp(code, data, message = 'ok', status = 200) {
  return new Response(JSON.stringify({ code, data, message }), {
    status,
    headers: JSON_HEADERS,
  });
}

function ok(data, message = 'ok') {
  return resp(0, data, message, 200);
}

function unauthorized(message = '未授权：令牌无效或缺失') {
  return resp(401, null, message, 401);
}

function badRequest(message) {
  return resp(400, null, message, 400);
}

function notFound(message = 'not found') {
  return resp(404, null, message, 404);
}

async function readJson(request) {
  try {
    const t = await request.text();
    if (!t) return {};
    return JSON.parse(t);
  } catch (_) {
    return null;
  }
}

function num(v, dflt = 0) {
  const n = Number(v);
  return Number.isFinite(n) ? n : dflt;
}

function byteLen(s) {
  try {
    return new TextEncoder().encode(s).byteLength;
  } catch (_) {
    return (s || '').length;
  }
}

function retentionOf(env) {
  const n = num(env.RETENTION, 10);
  return n > 0 ? Math.floor(n) : 10;
}

async function getProject(env, id) {
  return await env.DB.prepare(
    `SELECT project_key, name, kind, folder, edit_mode, count, rev, updated_at,
            last_device_id, last_device_name, deleted, created_at
       FROM projects WHERE project_key = ?`
  )
    .bind(id)
    .first();
}

async function writeSnapshot(env, id, rev, payload, body) {
  const r2Key = `snapshots/${id}/${rev}.json`;
  await env.BUCKET.put(r2Key, payload, {
    httpMetadata: { contentType: 'application/json; charset=utf-8' },
  });
  await env.DB.prepare(
    `INSERT INTO snapshots
       (project_key, rev, r2_key, size, label_count, device_id, device_name, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(
      id,
      rev,
      r2Key,
      byteLen(payload),
      num(body.count),
      (body.deviceId || '').toString(),
      (body.deviceName || '').toString(),
      Date.now()
    )
    .run();
}

async function pruneSnapshots(env, id) {
  const keep = retentionOf(env);
  const { results } = await env.DB.prepare(
    `SELECT rev, r2_key FROM snapshots WHERE project_key = ? ORDER BY rev DESC`
  )
    .bind(id)
    .all();
  const rows = results || [];
  const toDelete = revsToPrune(rows.map((r) => r.rev), keep);
  for (const rv of toDelete) {
    const row = rows.find((r) => Number(r.rev) === rv);
    if (row && row.r2_key) {
      try {
        await env.BUCKET.delete(row.r2_key);
      } catch (_) {}
    }
    await env.DB.prepare(
      `DELETE FROM snapshots WHERE project_key = ? AND rev = ?`
    )
      .bind(id, rv)
      .run();
  }
}

function conflictBody(row) {
  return {
    serverRev: num(row.rev),
    serverUpdatedAt: num(row.updated_at),
    serverDeviceId: row.last_device_id || '',
    serverDeviceName: row.last_device_name || '',
  };
}

// ===================== 处理函数 =====================

async function handlePing() {
  return ok({ serverTime: Date.now() });
}

async function handleIndex(env, url) {
  const since = url.searchParams.has('since') ? num(url.searchParams.get('since')) : 0;
  const { results } = await env.DB.prepare(
    `SELECT project_key, name, kind, folder, count, rev, updated_at,
            last_device_id, last_device_name, deleted
       FROM projects WHERE updated_at > ? ORDER BY updated_at DESC`
  )
    .bind(since)
    .all();
  const items = (results || []).map((r) => ({
    id: r.project_key,
    name: r.name || '',
    kind: r.kind || 'label',
    folder: r.folder || '',
    count: num(r.count),
    rev: num(r.rev),
    updatedAt: num(r.updated_at),
    lastDeviceId: r.last_device_id || '',
    lastDeviceName: r.last_device_name || '',
    deleted: num(r.deleted) === 1 ? 1 : 0,
  }));
  return ok({ items });
}

async function handleProjectGet(env, url, id) {
  const row = await getProject(env, id);
  if (!row) return notFound('工程不存在');
  // 取指定 rev（从 snapshots 找 r2_key）；缺省取当前 rev。
  let rev = num(url.searchParams.get('rev'), num(row.rev));
  if (!url.searchParams.has('rev')) rev = num(row.rev);
  const snap = await env.DB.prepare(
    `SELECT rev, r2_key, device_id, device_name, created_at
       FROM snapshots WHERE project_key = ? AND rev = ?`
  )
    .bind(id, rev)
    .first();
  let payload = '';
  if (snap && snap.r2_key) {
    const obj = await env.BUCKET.get(snap.r2_key);
    if (obj) payload = await obj.text();
  }
  return ok({
    id,
    rev,
    updatedAt: num(row.updated_at),
    lastDeviceId: row.last_device_id || '',
    lastDeviceName: row.last_device_name || '',
    meta: {
      name: row.name || '',
      kind: row.kind || 'label',
      folder: row.folder || '',
      editMode: row.edit_mode || 'design',
      count: num(row.count),
      deleted: num(row.deleted) === 1 ? 1 : 0,
    },
    payload,
  });
}

async function handleProjectPut(env, request, id) {
  const body = await readJson(request);
  if (body === null) return badRequest('请求体不是合法 JSON');
  const payload = typeof body.payload === 'string' ? body.payload : '';
  if (!payload) return badRequest('payload 不能为空');

  const now = Date.now();
  const row = await getProject(env, id);
  const baseRev = body.baseRev === null || body.baseRev === undefined
    ? null
    : num(body.baseRev);

  if (!row) {
    // 新建：rev=1（不带 baseRev 也接受，因为云端不存在，无覆盖风险）。
    const rev = 1;
    await env.DB.prepare(
      `INSERT INTO projects
         (project_key, name, kind, folder, edit_mode, count, rev, updated_at,
          last_device_id, last_device_name, deleted, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)`
    )
      .bind(
        id,
        (body.name || '').toString(),
        (body.kind || 'label').toString(),
        (body.folder || '').toString(),
        (body.editMode || 'design').toString(),
        num(body.count),
        rev,
        num(body.updatedAt, now),
        (body.deviceId || '').toString(),
        (body.deviceName || '').toString(),
        now
      )
      .run();
    await writeSnapshot(env, id, rev, payload, body);
    await pruneSnapshots(env, id);
    return ok({ rev });
  }

  // 已存在：乐观并发（缺失 baseRev → 不匹配 → 409，保守不覆盖）。
  if (!revAccepts(baseRev, row.rev)) {
    return resp(409, conflictBody(row), '版本冲突', 409);
  }
  const rev = num(row.rev) + 1;
  await env.DB.prepare(
    `UPDATE projects
        SET name = ?, kind = ?, folder = ?, edit_mode = ?, count = ?,
            rev = ?, updated_at = ?, last_device_id = ?, last_device_name = ?,
            deleted = 0
      WHERE project_key = ?`
  )
    .bind(
      (body.name || '').toString(),
      (body.kind || 'label').toString(),
      (body.folder || '').toString(),
      (body.editMode || 'design').toString(),
      num(body.count),
      rev,
      num(body.updatedAt, now),
      (body.deviceId || '').toString(),
      (body.deviceName || '').toString(),
      id
    )
    .run();
  await writeSnapshot(env, id, rev, payload, body);
  await pruneSnapshots(env, id);
  return ok({ rev });
}

async function handleProjectDelete(env, request, id) {
  const body = await readJson(request);
  if (body === null) return badRequest('请求体不是合法 JSON');
  const row = await getProject(env, id);
  if (!row) return notFound('工程不存在');
  const baseRev = body.baseRev === null || body.baseRev === undefined
    ? null
    : num(body.baseRev);
  if (!revAccepts(baseRev, row.rev)) {
    return resp(409, conflictBody(row), '版本冲突', 409);
  }
  const rev = num(row.rev) + 1;
  await env.DB.prepare(
    `UPDATE projects
        SET rev = ?, updated_at = ?, deleted = 1,
            last_device_id = ?, last_device_name = ?
      WHERE project_key = ?`
  )
    .bind(
      rev,
      Date.now(),
      (body.deviceId || '').toString(),
      (body.deviceName || '').toString(),
      id
    )
    .run();
  return ok({ rev });
}

async function handleHistory(env, id) {
  const row = await getProject(env, id);
  if (!row) return notFound('工程不存在');
  const { results } = await env.DB.prepare(
    `SELECT rev, created_at, device_name, label_count, size
       FROM snapshots WHERE project_key = ? ORDER BY rev DESC`
  )
    .bind(id)
    .all();
  const versions = (results || []).map((r) => ({
    rev: num(r.rev),
    updatedAt: num(r.created_at),
    deviceName: r.device_name || '',
    labelCount: num(r.label_count),
    size: num(r.size),
  }));
  return ok({ versions });
}

async function handleRestore(env, request, id) {
  const body = await readJson(request);
  if (body === null) return badRequest('请求体不是合法 JSON');
  const row = await getProject(env, id);
  if (!row) return notFound('工程不存在');
  const wantRev = num(body.rev, -1);
  const snap = await env.DB.prepare(
    `SELECT rev, r2_key FROM snapshots WHERE project_key = ? AND rev = ?`
  )
    .bind(id, wantRev)
    .first();
  if (!snap || !snap.r2_key) return notFound('目标版本不存在');
  const obj = await env.BUCKET.get(snap.r2_key);
  if (!obj) return notFound('目标版本内容缺失');
  const payload = await obj.text();

  const rev = num(row.rev) + 1;
  await env.DB.prepare(
    `UPDATE projects
        SET rev = ?, updated_at = ?, deleted = 0,
            last_device_id = ?, last_device_name = ?
      WHERE project_key = ?`
  )
    .bind(
      rev,
      Date.now(),
      (body.deviceId || '').toString(),
      (body.deviceName || '').toString(),
      id
    )
    .run();
  await writeSnapshot(env, id, rev, payload, {
    count: num(row.count),
    deviceId: body.deviceId,
    deviceName: body.deviceName,
  });
  await pruneSnapshots(env, id);
  return ok({ rev });
}

// ===================== 入口 =====================

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const route = routeOf(request.method, url.pathname);
    if (!route) return notFound('未知路由');

    // `/ping` 也需要鉴权（避免暴露内网 Worker），但不要求 payload。
    const provided = parseBearer(request.headers.get('Authorization'));
    const expected = (env.SYNC_TOKEN || '').trim();
    if (!expected || provided !== expected) {
      return unauthorized();
    }

    try {
      switch (route.name) {
        case 'ping':
          return await handlePing();
        case 'index':
          return await handleIndex(env, url);
        case 'projectGet':
          return await handleProjectGet(env, url, route.id);
        case 'projectPut':
          return await handleProjectPut(env, request, route.id);
        case 'projectDelete':
          return await handleProjectDelete(env, request, route.id);
        case 'history':
          return await handleHistory(env, route.id);
        case 'restore':
          return await handleRestore(env, request, route.id);
        default:
          return notFound('未知路由');
      }
    } catch (e) {
      return resp(500, null, `服务器错误：${e && e.message ? e.message : e}`, 500);
    }
  },
};
