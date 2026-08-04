import Testing

@testable import MTProtoPagination

@Suite("VectorHash — Telegram vector hash algorithm")
struct VectorHashTests {
  // Reference values produced by an independent BigInt transcription of the spec
  // at <https://corefork.telegram.org/api/offsets> (catches signed-shift/overflow
  // mistakes a same-language re-implementation would share).
  @Test("Matches reference vectors")
  func referenceVectors() {
    #expect(VectorHash.compute([Int64]()) == 0)
    #expect(VectorHash.compute([Int64(0)]) == 0)
    #expect(VectorHash.compute([Int64(1)]) == 1)
    #expect(VectorHash.compute([Int64(1), 2, 3]) == 565_224_272_838_726)
    #expect(VectorHash.compute([Int64(-1)]) == -1)
    #expect(VectorHash.compute([Int64.max, Int64.min]) == -576_456_629_134_819_328)
    #expect(
      VectorHash.compute([Int64(100), 200, 300, 400, 500]) == -4_766_965_692_942_897_286)
  }

  @Test("Order is significant")
  func orderMatters() {
    #expect(VectorHash.compute([Int64(1), 2, 3]) != VectorHash.compute([Int64(3), 2, 1]))
  }

  @Test("Incremental folding equals one-shot compute")
  func incrementalMatchesOneShot() {
    var h = VectorHash()
    for id in [Int64(7), 11, 13, 17] { h.combine(id) }
    #expect(h.value == VectorHash.compute([Int64(7), 11, 13, 17]))
  }

  @Test("Int32 ids widen to the same hash as their Int64 values")
  func int32WidensConsistently() {
    let ids32: [Int32] = [100, 200, 300, 400, 500]
    let ids64 = ids32.map(Int64.init)
    #expect(VectorHash.compute(ids32) == VectorHash.compute(ids64))
  }

  @Test("Empty input hashes to zero")
  func emptyIsZero() {
    #expect(VectorHash.compute([Int64]()) == 0)
    #expect(VectorHash().value == 0)
  }
}

@Suite("VectorHash — NotModified decision")
struct NotModifiedTests {
  @Test("Matching non-zero client hash → notModified")
  func matchingShortCircuits() {
    let current = VectorHash.compute([Int64(42), 43])
    #expect(VectorHash.state(clientHash: current, current: current) == .notModified)
  }

  @Test("Differing client hash → modified with the fresh hash")
  func differingReturnsFresh() {
    let current = VectorHash.compute([Int64(42), 43])
    #expect(VectorHash.state(clientHash: 999, current: current) == .modified(hash: current))
  }

  @Test("Client hash 0 always rebuilds, even when the real hash is 0")
  func zeroClientHashNeverMatches() {
    // An empty list hashes to 0; a first-time client (hash 0) must still get data.
    #expect(VectorHash.state(clientHash: 0, current: 0) == .modified(hash: 0))
    #expect(VectorHash.state(clientHash: 0, over: [Int64]()) == .modified(hash: 0))
  }

  @Test("over: folds and compares in one step")
  func overConvenience() {
    let ids = [Int64(5), 6, 7]
    let current = VectorHash.compute(ids)
    #expect(VectorHash.state(clientHash: current, over: ids) == .notModified)
    #expect(VectorHash.state(clientHash: 1, over: ids) == .modified(hash: current))
  }
}
