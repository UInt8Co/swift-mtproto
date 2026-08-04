/// Folds a sequence of 64-bit ids into Telegram's vector hash, the value that
/// drives the `*NotModified` short-circuit.
///
/// Order is significant: fold ids in the order the peer folds them. The result is
/// ``value``. See <doc:MTProtoPagination> for the algorithm.
public struct VectorHash: Sendable, Equatable {
  /// The raw unsigned accumulator. Exposed for testing/inspection.
  public private(set) var accumulator: UInt64 = 0

  public init() {}

  /// Folds one id into the running hash.
  public mutating func combine(_ id: Int64) {
    accumulator ^= accumulator >> 21
    accumulator ^= accumulator << 35
    accumulator ^= accumulator >> 4
    accumulator = accumulator &+ UInt64(bitPattern: id)
  }

  /// Folds a 32-bit id, widened to 64 bits as the reference clients do.
  public mutating func combine(_ id: Int32) {
    combine(Int64(id))
  }

  /// The folded hash, as the signed `Int64` that goes on the wire.
  public var value: Int64 { Int64(bitPattern: accumulator) }
}

extension VectorHash {
  /// Folds a whole sequence of 64-bit ids and returns the wire hash.
  public static func compute<S: Sequence>(_ ids: S) -> Int64 where S.Element == Int64 {
    var hash = VectorHash()
    for id in ids { hash.combine(id) }
    return hash.value
  }

  /// Folds a whole sequence of 32-bit ids and returns the wire hash.
  public static func compute<S: Sequence>(_ ids: S) -> Int64 where S.Element == Int32 {
    var hash = VectorHash()
    for id in ids { hash.combine(id) }
    return hash.value
  }
}
