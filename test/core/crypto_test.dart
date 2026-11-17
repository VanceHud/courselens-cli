import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:courselens/core/courselens_core.dart';
import 'package:test/test.dart';

class _FixedRandom implements SecureRandom {
  int calls = 0;

  @override
  Uint8List bytes(int length) {
    calls++;
    return Uint8List.fromList(List<int>.filled(length, 0x42));
  }
}

class _ZeroInjectingRandom implements SecureRandom {
  int _step = 0;

  @override
  Uint8List bytes(int length) {
    _step++;
    if (_step == 1) {
      return Uint8List(length); // 全 0，测试非零填充过滤重试
    }
    return Uint8List.fromList(List<int>.filled(length, 0x37));
  }
}

void main() {
  const modulus512 =
      'b1d2af160ebaa47adfef6e4f98a6f1045bd6dc5bfba4bf427c9a653307424d95'
      '5bf9bbe79a6f5444b7bb04dc8fd4d4c36063d67fbab5c6732b6a2ed6bbf6f45d';
  const exponentHex = '10001';

  const goldenCiphertexts = <String, String>{
    'Test1234':
        '67c1c3ced32581ae2625105404296e398ce4c021eec4483f55ba63b7f4752c09'
        '70b92d0c17c50481346d8d2fc5d89ff906d35091a0792f74e0b0ff5ce977a370',
    'a':
        '6f4d2eb2551782bb43dddc6355a1f93612fffca2139f9adb4a09ccec2a5cc2f1'
        'dc9e80ce249a301eeb7476bfbbe243cf74b9171c146bba106639288d214a7a6a',
    'ab':
        '3b07a2c88ff9d8e9ad4effd6de2a7012df99d68ae067e809db3f095fc7cc1e25'
        '689e26995ee8c5f1cd786b7706889896b9db89c2a17b80cf05f87b3486d8d1a7',
    'P@ss/w0rd-9Xz':
        '7d7a4b8d04a09888caf0a54fc32345227c418f6303e25b9288cf0d3136f17752'
        '98517318d2e83947ddd9b6d61e752d4419552b2e8b950ea2d35d720b0ea2be24',
    '密码pass1234':
        '429567c3187920e19656641f1c88e2c27d9568d328edce24ce52ea9a3f38e1ee'
        '2d0d918c48331571be21dad65f69169763b874cb1c0ea399e1aec7ed37de91ea',
  };

  group('Base64Codec', () {
    test('round-trips arbitrary byte lengths and tolerates whitespace', () {
      for (var len = 0; len <= 32; len++) {
        final input = Uint8List.fromList(List<int>.generate(len, (i) => i * 7));
        final encoded = Base64Codec.encode(input);
        expect(Base64Codec.decode(encoded), equals(input));
        expect(Base64Codec.decode('  $encoded\r\n '), equals(input));
      }
    });

    test('rejects invalid characters, misplaced padding and dirty tail bits', () {
      expect(Base64Codec.decode('not!valid@base64'), isNull);
      expect(Base64Codec.decode('YQ=a'), isNull);
      expect(Base64Codec.decode('==='), isNull);
      // 'AB==' has non-zero trailing bits in 'B' (index 1 -> low 4 bits = 0001).
      expect(Base64Codec.decode('AB=='), isNull);
    });
  });

  group('ZhengfangRsa (CAS security.js)', () {
    test('matches all 5 upstream golden ciphertexts byte-for-byte', () {
      for (final entry in goldenCiphertexts.entries) {
        final actual = ZhengfangRsa.encryptPassword(
          entry.key,
          modulus512,
          exponentHex,
        );
        expect(
          actual,
          equals(entry.value),
          reason: 'Golden mismatch for password: ${entry.key}',
        );
      }
    });

    test('chunks long passwords with space-separated blocks', () {
      final longPw = 'A' * 80;
      final cipher = ZhengfangRsa.encryptPassword(
        longPw,
        modulus512,
        exponentHex,
      );
      expect(cipher.contains(' '), isTrue);
      expect(cipher.split(' ').length, greaterThan(1));
    });

    test('rejects malformed hex modulus instead of returning plaintext', () {
      expect(
        () => ZhengfangRsa.encryptPassword('secret', 'zz-not-hex', exponentHex),
        throwsA(isA<ZhengfangRsaCryptoException>()),
      );
    });
  });

  group('RsaPkcs1 (jwglxt native PKCS#1 v1.5)', () {
    test('handles 129-byte leading-0x00 QUST public key as 128-byte block', () {
      final pubJson =
          File('test/fixtures/academic/qust-publickey.json').readAsStringSync();
      final key = ZhengfangJwglxtProtocol.parsePublicKey(pubJson);
      final rawModulus = Base64Codec.decode(key.modulusBase64)!;
      expect(rawModulus.length, equals(129));
      expect(rawModulus[0], equals(0));

      final rng = _FixedRandom();
      final cipher = RsaPkcs1.encryptPassword(
        password: 'hunter2',
        modulusBase64: key.modulusBase64,
        exponentBase64: key.exponentBase64,
        random: rng,
      );
      expect(rng.calls, greaterThan(0));
      // 128 bytes -> 172 Base64 chars ending with '='
      expect(cipher.length, equals(172));
      expect(cipher.endsWith('='), isTrue);
      expect(cipher.contains(' '), isFalse);
      expect(Base64Codec.decode(cipher)?.length, equals(128));
    });

    test('pkcs1Block strips 0x00 bytes from random padding', () {
      final block = RsaPkcs1.pkcs1Block(
        Uint8List.fromList(utf8.encode('abc')),
        128,
        _ZeroInjectingRandom(),
      );
      expect(block[0], equals(0x00));
      expect(block[1], equals(0x02));
      // Bytes 2..123 are non-zero PS, byte 124 is 0x00 separator, 125..127 = 'abc'
      for (var i = 2; i < 124; i++) {
        expect(block[i], isNonZero);
      }
      expect(block[124], equals(0x00));
    });

    test('throws on malformed Base64 key rather than leaking password', () {
      expect(
        () => RsaPkcs1.encryptPassword(
          password: 'pw',
          modulusBase64: '!!!',
          exponentBase64: 'AQAB',
          random: _FixedRandom(),
        ),
        throwsA(isA<RsaPkcs1CryptoException>()),
      );
    });
  });
}
