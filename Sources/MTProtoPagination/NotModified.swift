/// The outcome of comparing a cached vector hash against the current data.
public enum VectorHashState: Sendable, Equatable {
  /// The hashes match; respond with the type's `*NotModified` variant.
  case notModified
  /// No cached copy, or changed data: build the full response with this `hash`.
  case modified(hash: Int64)
}

extension VectorHash {
  /// Compares an already-computed `current` hash against the request's
  /// `clientHash`.
  ///
  /// `clientHash == 0` is the "I have no cached copy" sentinel and never matches,
  /// even when the real hash of an empty list happens to be `0`.
  public static func state(clientHash: Int64, current: Int64) -> VectorHashState {
    clientHash != 0 && clientHash == current ? .notModified : .modified(hash: current)
  }

  /// Folds `ids` into a hash and compares it against `clientHash` in one step.
  public static func state<S: Sequence>(clientHash: Int64, over ids: S) -> VectorHashState
  where S.Element == Int64 {
    state(clientHash: clientHash, current: compute(ids))
  }

  /// Folds 32-bit `ids` into a hash and compares it against `clientHash`.
  public static func state<S: Sequence>(clientHash: Int64, over ids: S) -> VectorHashState
  where S.Element == Int32 {
    state(clientHash: clientHash, current: compute(ids))
  }
}
