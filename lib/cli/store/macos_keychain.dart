import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'cli_session_store.dart';

abstract interface class CliKeychain {
  String? read(String service, String account);
  void write(String service, String account, String value);
  void delete(String service, String account);
}

/// Uses the macOS login keychain and the same generic-password item as older CLI versions.
class MacOsKeychain implements CliKeychain {
  static const _notFound = -25300;
  static const _duplicateItem = -25299;

  final _security = DynamicLibrary.open(
    '/System/Library/Frameworks/Security.framework/Security',
  );
  final _coreFoundation = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
  );

  late final _find = _security.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Uint32,
        Pointer<Utf8>,
        Uint32,
        Pointer<Utf8>,
        Pointer<Uint32>,
        Pointer<Pointer<Void>>,
        Pointer<Pointer<Void>>,
      ),
      int Function(
        Pointer<Void>,
        int,
        Pointer<Utf8>,
        int,
        Pointer<Utf8>,
        Pointer<Uint32>,
        Pointer<Pointer<Void>>,
        Pointer<Pointer<Void>>,
      )>('SecKeychainFindGenericPassword');
  late final _add = _security.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Uint32,
        Pointer<Utf8>,
        Uint32,
        Pointer<Utf8>,
        Uint32,
        Pointer<Utf8>,
        Pointer<Pointer<Void>>,
      ),
      int Function(
        Pointer<Void>,
        int,
        Pointer<Utf8>,
        int,
        Pointer<Utf8>,
        int,
        Pointer<Utf8>,
        Pointer<Pointer<Void>>,
      )>('SecKeychainAddGenericPassword');
  late final _modify = _security.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Pointer<Utf8>),
      int Function(Pointer<Void>, Pointer<Void>, int,
          Pointer<Utf8>)>('SecKeychainItemModifyAttributesAndData');
  late final _delete = _security.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('SecKeychainItemDelete');
  late final _freeContent = _security.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)>('SecKeychainItemFreeContent');
  late final _release = _coreFoundation.lookupFunction<
      Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');

  @override
  String? read(String service, String account) => using((arena) {
        final serviceName = service.toNativeUtf8(allocator: arena);
        final accountName = account.toNativeUtf8(allocator: arena);
        final length = arena<Uint32>();
        final data = arena<Pointer<Void>>();
        final status = _find(
          nullptr,
          serviceName.length,
          serviceName,
          accountName.length,
          accountName,
          length,
          data,
          nullptr,
        );
        if (status == _notFound) return null;
        _check(status, 'read');
        try {
          if (length.value == 0) return '';
          return utf8
              .decode(data.value.cast<Uint8>().asTypedList(length.value));
        } finally {
          if (data.value != nullptr) _freeContent(nullptr, data.value);
        }
      });

  @override
  void write(String service, String account, String value) {
    using((arena) {
      final serviceName = service.toNativeUtf8(allocator: arena);
      final accountName = account.toNativeUtf8(allocator: arena);
      final data = value.toNativeUtf8(allocator: arena);
      final length = data.length;
      try {
        final status = _add(
          nullptr,
          serviceName.length,
          serviceName,
          accountName.length,
          accountName,
          length,
          data,
          nullptr,
        );
        if (status != _duplicateItem) {
          _check(status, 'save');
          return;
        }
        _withItem(
          serviceName,
          accountName,
          arena,
          'update',
          (item) => _modify(item, nullptr, length, data),
        );
      } finally {
        data.cast<Uint8>().asTypedList(length).fillRange(0, length, 0);
      }
    });
  }

  @override
  void delete(String service, String account) {
    using((arena) {
      _withItem(
        service.toNativeUtf8(allocator: arena),
        account.toNativeUtf8(allocator: arena),
        arena,
        'delete',
        _delete,
      );
    });
  }

  void _withItem(
    Pointer<Utf8> service,
    Pointer<Utf8> account,
    Arena arena,
    String operation,
    int Function(Pointer<Void>) apply,
  ) {
    final item = arena<Pointer<Void>>();
    final status = _find(
      nullptr,
      service.length,
      service,
      account.length,
      account,
      nullptr,
      nullptr,
      item,
    );
    if (status == _notFound && operation == 'delete') return;
    _check(status, operation);
    try {
      final result = apply(item.value);
      if (result == _notFound && operation == 'delete') return;
      _check(result, operation);
    } finally {
      _release(item.value);
    }
  }

  static void _check(int status, String operation) {
    if (status != 0) {
      throw CliStorageUnavailableException(
        'macOS Keychain $operation failed (OSStatus $status).',
      );
    }
  }
}
