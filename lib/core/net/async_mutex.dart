import 'dart:async';
import 'dart:collection';

/// 纯 Dart FIFO 异步互斥锁，等价于 Kotlin `kotlinx.coroutines.sync.Mutex`。
class AsyncMutex {
  bool _locked = false;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> withLock<T>(FutureOr<T> Function() action) async {
    if (_locked) {
      final waiter = Completer<void>();
      _waiters.addLast(waiter);
      await waiter.future;
    } else {
      _locked = true;
    }
    try {
      return await action();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _locked = false;
      }
    }
  }
}
