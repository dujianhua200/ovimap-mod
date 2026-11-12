// Worker 纯逻辑单测（node --test，无需 Cloudflare 账号）。
// 运行：node --test cloudflare/test/
import test from 'node:test';
import assert from 'node:assert/strict';

import { revAccepts, revsToPrune, parseBearer, routeOf } from '../src/index.js';

test('revAccepts：baseRev == currentRev 才接受', () => {
  assert.equal(revAccepts(7, 7), true);
  assert.equal(revAccepts(0, 0), true);
  assert.equal(revAccepts(6, 7), false);
  assert.equal(revAccepts(8, 7), false);
});

test('revAccepts：baseRev 缺失 → 不匹配（保守不覆盖）', () => {
  assert.equal(revAccepts(null, 5), false);
  assert.equal(revAccepts(undefined, 5), false);
});

test('revsToPrune：保留最近 N 版，返回更旧的应删除集', () => {
  assert.deepEqual(revsToPrune([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], 10), [1, 2]);
  assert.deepEqual(revsToPrune([3, 1, 2], 10), []);
  assert.deepEqual(revsToPrune([5, 1, 3, 2, 4], 3), [1, 2]);
  assert.deepEqual(revsToPrune([1, 2, 3], 0), [1, 2, 3]);
});

test('parseBearer：支持 Bearer 前缀与裸令牌', () => {
  assert.equal(parseBearer('Bearer abc'), 'abc');
  assert.equal(parseBearer('bearer abc'), 'abc');
  assert.equal(parseBearer('abc'), 'abc');
  assert.equal(parseBearer(''), '');
  assert.equal(parseBearer(undefined), '');
});

test('routeOf：路由与参数解析', () => {
  assert.deepEqual(routeOf('GET', '/ping'), { name: 'ping' });
  assert.deepEqual(routeOf('GET', '/index'), { name: 'index' });
  assert.deepEqual(routeOf('GET', '/project/c1'), { name: 'projectGet', id: 'c1' });
  assert.deepEqual(routeOf('PUT', '/project/c1'), { name: 'projectPut', id: 'c1' });
  assert.deepEqual(routeOf('DELETE', '/project/c1'), { name: 'projectDelete', id: 'c1' });
  assert.deepEqual(routeOf('GET', '/project/c1/history'), { name: 'history', id: 'c1' });
  assert.deepEqual(routeOf('POST', '/project/c1/restore'), { name: 'restore', id: 'c1' });
  assert.deepEqual(routeOf('GET', '/project/c%201'), { name: 'projectGet', id: 'c 1' });
  assert.equal(routeOf('POST', '/project/c1'), null);
  assert.equal(routeOf('GET', '/nope'), null);
});
