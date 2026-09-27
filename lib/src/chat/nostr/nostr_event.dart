import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashing;

import 'bip340.dart';

final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _hex128 = RegExp(r'^[0-9a-f]{128}$');

/// Thrown when relay data is not a well-formed NIP-01 event.
class NostrEventFormatException implements FormatException {
  /// Creates an exception describing which check failed.
  const NostrEventFormatException(this.message);

  @override
  final String message;
  @override
  Object? get source => null;
  @override
  int? get offset => null;

  @override
  String toString() => 'NostrEventFormatException: $message';
}

/// A secp256k1 key used only to sign the outer Nostr envelope.
///
/// This key proves nothing about who sent a chat message: that is the job of
/// the Ed25519 signature inside the packet. It exists because relays refuse
/// events without a valid BIP-340 signature.
class NostrKeyPair {
  NostrKeyPair._(this.privateKeyHex, this.publicKeyHex);

  /// Builds a key pair from a 32-byte private key in lowercase hex.
  factory NostrKeyPair.fromPrivateKeyHex(String privateKeyHex) {
    final normalized = privateKeyHex.toLowerCase();
    if (!_hex64.hasMatch(normalized)) {
      throw ArgumentError.value(privateKeyHex, 'privateKeyHex', 'not 32 bytes');
    }
    final scalar = BigInt.parse(normalized, radix: 16);
    if (scalar == BigInt.zero || scalar >= secp256k1Order) {
      throw ArgumentError.value(privateKeyHex, 'privateKeyHex', 'out of range');
    }
    return NostrKeyPair._(normalized, bip340PublicKey(normalized));
  }

  /// Generates a fresh key from a secure random source.
  factory NostrKeyPair.generate([Random? random]) {
    final source = random ?? Random.secure();
    while (true) {
      final candidate = _toHex(
        List<int>.generate(32, (_) => source.nextInt(256)),
      );
      final scalar = BigInt.parse(candidate, radix: 16);
      if (scalar != BigInt.zero && scalar < secp256k1Order) {
        return NostrKeyPair._(candidate, bip340PublicKey(candidate));
      }
    }
  }

  /// Private scalar, 32 bytes in lowercase hex. Secret; do not log it.
  final String privateKeyHex;

  /// X-only public key, 32 bytes in lowercase hex.
  final String publicKeyHex;
}

/// A NIP-01 event.
class NostrEvent {
  /// Creates an event from its fields without computing or checking the id
  /// or signature. Use [sign] to build a new event.
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// Creates and signs an event.
  static NostrEvent sign({
    required NostrKeyPair keys,
    required int kind,
    required List<List<String>> tags,
    required String content,
    required DateTime createdAt,
    Random? random,
  }) {
    final seconds = createdAt.toUtc().millisecondsSinceEpoch ~/ 1000;
    final id = computeId(
      pubkey: keys.publicKeyHex,
      createdAt: seconds,
      kind: kind,
      tags: tags,
      content: content,
    );
    final source = random ?? Random.secure();
    final aux = _toHex(List<int>.generate(32, (_) => source.nextInt(256)));
    return NostrEvent(
      id: id,
      pubkey: keys.publicKeyHex,
      createdAt: seconds,
      kind: kind,
      tags: [for (final tag in tags) List.unmodifiable(tag)],
      content: content,
      sig: bip340Sign(keys.privateKeyHex, id, aux),
    );
  }

  /// SHA-256 over the NIP-01 serialization.
  static String computeId({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    final serialized = jsonEncode([0, pubkey, createdAt, kind, tags, content]);
    return hashing.sha256.convert(utf8.encode(serialized)).toString();
  }

  /// Parses relay JSON, checking shape only; call [verify] before trusting it.
  static NostrEvent fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const NostrEventFormatException('event is not an object');
    }
    final id = json['id'];
    final pubkey = json['pubkey'];
    final createdAt = json['created_at'];
    final kind = json['kind'];
    final rawTags = json['tags'];
    final content = json['content'];
    final sig = json['sig'];
    if (id is! String || !_hex64.hasMatch(id)) {
      throw const NostrEventFormatException('invalid id');
    }
    if (pubkey is! String || !_hex64.hasMatch(pubkey)) {
      throw const NostrEventFormatException('invalid pubkey');
    }
    if (sig is! String || !_hex128.hasMatch(sig)) {
      throw const NostrEventFormatException('invalid sig');
    }
    if (createdAt is! int || createdAt < 0) {
      throw const NostrEventFormatException('invalid created_at');
    }
    if (kind is! int || kind < 0 || kind > 65535) {
      throw const NostrEventFormatException('invalid kind');
    }
    if (content is! String) {
      throw const NostrEventFormatException('invalid content');
    }
    if (rawTags is! List || rawTags.length > 64) {
      throw const NostrEventFormatException('invalid tags');
    }
    final tags = <List<String>>[];
    for (final tag in rawTags) {
      if (tag is! List || tag.isEmpty || tag.length > 8) {
        throw const NostrEventFormatException('invalid tag');
      }
      final values = <String>[];
      for (final value in tag) {
        if (value is! String || value.length > 1024) {
          throw const NostrEventFormatException('invalid tag value');
        }
        values.add(value);
      }
      tags.add(List.unmodifiable(values));
    }
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: List.unmodifiable(tags),
      content: content,
      sig: sig,
    );
  }

  /// Event id: SHA-256 of the NIP-01 serialization, 32 bytes in lowercase
  /// hex.
  final String id;

  /// Author's x-only secp256k1 public key, 32 bytes in lowercase hex.
  ///
  /// For events from this plugin this is usually a single-use envelope key
  /// and says nothing about the chat sender.
  final String pubkey;

  /// Unix time in seconds.
  final int createdAt;

  /// Event kind, 0 to 65535.
  final int kind;

  /// Tags as lists of strings; the first element is the tag name.
  final List<List<String>> tags;

  /// Event payload text.
  final String content;

  /// BIP-340 Schnorr signature over [id], 64 bytes in lowercase hex.
  final String sig;

  /// The first value of the first tag named [name], if any.
  String? tag(String name) {
    for (final tag in tags) {
      if (tag.length >= 2 && tag[0] == name) return tag[1];
    }
    return null;
  }

  /// Whether the id matches the content and the signature matches the id.
  bool verify() {
    final expected = computeId(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
    if (expected != id) return false;
    try {
      return bip340Verify(pubkey, id, sig);
    } on Object {
      // Defensive: verification must never throw on hostile input.
      return false;
    }
  }

  /// NIP-01 JSON object with the wire field names, such as `created_at`.
  Map<String, Object> toJson() => {
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };
}

String _toHex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
