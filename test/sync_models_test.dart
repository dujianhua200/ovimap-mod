// T13：同步数据模型 + 纯函数（零网络、零 IO）。
import 'package:flutter_test/flutter_test.dart';

import 'package:ovimap/sync/sync_models.dart';

void main() {
  group('SyncStatus 徽标/文案/颜色', () {
    test('四种状态的徽标与中文一致', () {
      expect(SyncStatus.synced.badge, '✓');
      expect(SyncStatus.pendingUpload.badge, '↑');
      expect(SyncStatus.conflict.badge, '⚠');
      expect(SyncStatus.localOnly.badge, '●');
      expect(SyncStatus.synced.label, '已同步');
      expect(SyncStatus.pendingUpload.label, '待上传');
      expect(SyncStatus.conflict.label, '有冲突');
      expect(SyncStatus.localOnly.label, '仅本地');
      // 颜色均为不透明 ARGB。
      for (final s in SyncStatus.values) {
        expect(s.argb & 0xFF000000, 0xFF000000, reason: '$s 颜色应不透明');
      }
    });

    test('syncStatusFromName：已知名解析，未知/缺省 → localOnly', () {
      expect(syncStatusFromName('synced'), SyncStatus.synced);
      expect(syncStatusFromName('pendingUpload'), SyncStatus.pendingUpload);
      expect(syncStatusFromName('conflict'), SyncStatus.conflict);
      expect(syncStatusFromName('localOnly'), SyncStatus.localOnly);
      expect(syncStatusFromName('unknown'), SyncStatus.localOnly);
      expect(syncStatusFromName(null), SyncStatus.localOnly);
    });
  });

  group('SyncMeta 主键为 cid，序列化缺省容错', () {
    test('toJson/fromJson 往返', () {
      final m = SyncMeta(
        cid: 'c1',
        rev: 7,
        updatedAt: 1730000000000,
        lastDeviceId: 'dev-A',
        lastDeviceName: '电脑-信阳',
        status: SyncStatus.synced,
      );
      final back = SyncMeta.fromJson('c1', m.toJson());
      expect(back.rev, 7);
      expect(back.updatedAt, 1730000000000);
      expect(back.lastDeviceId, 'dev-A');
      expect(back.lastDeviceName, '电脑-信阳');
      expect(back.status, SyncStatus.synced);
    });

    test('fromJson 缺省：rev=0 / status=localOnly', () {
      final back = SyncMeta.fromJson('cX', <String, dynamic>{});
      expect(back.cid, 'cX');
      expect(back.rev, 0);
      expect(back.updatedAt, 0);
      expect(back.status, SyncStatus.localOnly);
    });

    test('copyWith 只改指定字段', () {
      final m = SyncMeta(cid: 'c', rev: 1);
      final n = m.copyWith(rev: 2, status: SyncStatus.conflict);
      expect(n.cid, 'c');
      expect(n.rev, 2);
      expect(n.status, SyncStatus.conflict);
      expect(n.lastDeviceName, '');
    });
  });

  group('QueueItem 序列化', () {
    test('往返保留全部字段', () {
      final q = QueueItem(
        cid: 'c1',
        op: SyncOp.delete,
        baseRev: 3,
        enqueuedAt: 100,
        attempts: 2,
        lastError: 'boom',
      );
      final back = QueueItem.fromJson(q.toJson());
      expect(back.cid, 'c1');
      expect(back.op, SyncOp.delete);
      expect(back.baseRev, 3);
      expect(back.enqueuedAt, 100);
      expect(back.attempts, 2);
      expect(back.lastError, 'boom');
    });
  });

  group('RemoteIndexEntry deleted 解析', () {
    test('1 / true / 缺省', () {
      expect(
          RemoteIndexEntry.fromJson(<String, dynamic>{'id': 'a', 'deleted': 1})
              .deleted,
          isTrue);
      expect(
          RemoteIndexEntry.fromJson(<String, dynamic>{'id': 'a', 'deleted': true})
              .deleted,
          isTrue);
      expect(
          RemoteIndexEntry.fromJson(<String, dynamic>{'id': 'a'}).deleted,
          isFalse);
      expect(
          RemoteIndexEntry.fromJson(<String, dynamic>{'id': 'a', 'deleted': 0})
              .deleted,
          isFalse);
    });
  });

  group('PutResult（sealed）', () {
    test('PutOk / PutConflict 可判别', () {
      const PutResult ok = PutOk(5);
      const PutResult cf = PutConflict(serverRev: 9, serverDeviceName: '手机');
      expect(ok is PutOk, isTrue);
      expect(ok is PutConflict, isFalse);
      expect(cf is PutConflict, isTrue);
      if (cf is PutConflict) {
        expect(cf.serverRev, 9);
        expect(cf.serverDeviceName, '手机');
      }
    });
  });

  group('revAccepts：乐观并发判据（与 Worker 对齐）', () {
    test('baseRev 等于当前 rev → 接受', () {
      expect(revAccepts(baseRev: 7, currentRev: 7), isTrue);
      expect(revAccepts(baseRev: 0, currentRev: 0), isTrue);
    });
    test('baseRev 缺失/不等 → 拒绝（保守不覆盖）', () {
      expect(revAccepts(baseRev: null, currentRev: 7), isFalse);
      expect(revAccepts(baseRev: 6, currentRev: 7), isFalse);
      expect(revAccepts(baseRev: 8, currentRev: 7), isFalse);
    });
  });

  group('revsToPrune：保留最近 N 版', () {
    test('超过 keep → 返回更旧的应删除集（升序）', () {
      expect(revsToPrune(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], 10),
          <int>[1, 2]);
    });
    test('不超过 keep → 不删', () {
      expect(revsToPrune(<int>[3, 1, 2], 10), isEmpty);
      expect(revsToPrune(<int>[], 10), isEmpty);
    });
    test('乱序输入也能正确裁剪', () {
      expect(revsToPrune(<int>[5, 1, 3, 2, 4], 3), <int>[1, 2]);
    });
    test('keep<=0 → 全删', () {
      expect(revsToPrune(<int>[1, 2, 3], 0), <int>[1, 2, 3]);
    });
  });
}
