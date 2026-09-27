/// A token-bucket budget: [burst] packets at once, refilled at [perSecond].
class InboundRateLimit {
  /// Creates a budget. [burst] must be positive and [perSecond] must not be
  /// negative; zero means the bucket never refills.
  const InboundRateLimit({required this.burst, required this.perSecond})
    : assert(burst > 0),
      assert(perSecond >= 0);

  /// Bucket capacity: packets accepted back to back from a full bucket.
  final int burst;

  /// Tokens restored per second, up to [burst].
  final double perSecond;
}

/// Reported when inbound traffic exceeds a budget and is being dropped.
///
/// Emitted at most once per key per reporting window, so a flood does not
/// become a flood of errors.
class InboundRateLimitedException implements Exception {
  /// Creates an exception for the budget identified by [key].
  const InboundRateLimitedException(this.key);

  /// `sender:<peer id>` or `route:<transport>:<route>`.
  final String key;

  @override
  String toString() =>
      'InboundRateLimitedException: dropping traffic from $key';
}

/// Reported when a transport accepts only known contacts and a packet
/// arrived from a sender with no pinned key.
class UnknownSenderException implements Exception {
  /// Creates an exception for [senderId] on [transportId].
  const UnknownSenderException(this.senderId, this.transportId);

  /// Claimed peer id of the rejected sender.
  final String senderId;

  /// Transport that required a known contact.
  final String transportId;

  @override
  String toString() =>
      'UnknownSenderException: $senderId is not a contact on $transportId';
}

/// Bounded set of token buckets keyed by sender or route.
class TokenBuckets {
  /// Creates buckets that each follow [limit], tracking at most
  /// [maximumKeys] keys. [clock] defaults to [DateTime.now].
  TokenBuckets(
    this.limit, {
    this.maximumKeys = 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Budget applied to every key.
  final InboundRateLimit limit;

  /// Keys tracked before the least recently used one is evicted.
  final int maximumKeys;
  final DateTime Function() _clock;
  final Map<String, _Bucket> _buckets = {};

  /// Spends one token for [key]; false when the budget is exhausted.
  bool take(String key) {
    final now = _clock();
    var bucket = _buckets.remove(key);
    if (bucket == null) {
      _makeRoom();
      bucket = _Bucket(limit.burst.toDouble(), now);
    } else {
      final elapsed = now.difference(bucket.updatedAt).inMicroseconds / 1e6;
      bucket
        ..tokens = (bucket.tokens + elapsed * limit.perSecond).clamp(
          0,
          limit.burst.toDouble(),
        )
        ..updatedAt = now;
    }
    // Reinserting keeps the map ordered by recent use.
    _buckets[key] = bucket;
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }

  /// Evicts least-recently-used keys. An evicted key restarts with a full
  /// burst, so churn through many keys is still capped by the route budget.
  void _makeRoom() {
    while (_buckets.length >= maximumKeys) {
      _buckets.remove(_buckets.keys.first);
    }
  }
}

class _Bucket {
  _Bucket(this.tokens, this.updatedAt);

  double tokens;
  DateTime updatedAt;
}
