import 'chat_keys.dart';

/// How a peer's key compares with what we already trusted.
enum PeerTrust {
  /// First time we have seen this peer. The key is now pinned.
  firstContact,

  /// Same key as last time.
  known,

  /// A different key for a peer id we already trusted.
  ///
  /// Because the peer id is a fingerprint of the signing key, this cannot
  /// represent a signing-key replacement. It normally means the agreement
  /// key changed while the signing key remained the same.
  changed,
}

/// Trust-on-first-use record of which key belongs to which peer.
///
/// TOFU is a deliberate trade-off. It stops a stranger from silently becoming
/// an existing contact, which is the attack that matters in a room full of
/// phones, without demanding a fingerprint comparison that most people will
/// not complete. It does not protect the very first contact.
class TrustStore {
  /// Creates a store seeded with a copy of [pinned], keyed by peer id.
  ///
  /// Entries are not checked against their fingerprints.
  TrustStore({Map<String, ChatPublicKeys>? pinned}) : _pinned = {...?pinned};

  final Map<String, ChatPublicKeys> _pinned;

  /// Read-only view of every pinned peer id and its keys, for persistence.
  Map<String, ChatPublicKeys> get pinned => Map.unmodifiable(_pinned);

  /// Pinned keys for [peerId], or null if none are pinned.
  ChatPublicKeys? keysFor(String peerId) => _pinned[peerId];

  /// Classifies [keys] for [peerId] without changing anything.
  PeerTrust classify(String peerId, ChatPublicKeys keys) {
    final existing = _pinned[peerId];
    if (existing == null) return PeerTrust.firstContact;
    return existing == keys ? PeerTrust.known : PeerTrust.changed;
  }

  /// Records [keys] on first contact.
  ///
  /// A changed key is never adopted silently: the caller has to decide, which
  /// is what makes the rotation prompt possible instead of a takeover.
  PeerTrust observe(String peerId, ChatPublicKeys keys) {
    final verdict = classify(peerId, keys);
    if (verdict == PeerTrust.firstContact) _pinned[peerId] = keys;
    return verdict;
  }

  /// Accepts a replacement key after the user has approved it.
  ///
  /// Throws [ArgumentError] if [keys] do not derive [peerId], so a different
  /// signing key can never be adopted under an existing id. Only the
  /// fingerprint is checked; comparing keys out of band is the caller's job.
  void acceptRotation(String peerId, ChatPublicKeys keys) {
    if (keys.peerId != peerId) {
      throw ArgumentError('replacement key must match its fingerprint peer id');
    }
    _pinned[peerId] = keys;
  }

  /// Removes the pin for [peerId]; its next keys count as first contact.
  void forget(String peerId) => _pinned.remove(peerId);
}
