import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import MTProtoUtils

/// Tests for ``TLInt53`` — the entity-id wrapper that guarantees a value stays
/// within the JavaScript-safe integer range `-(2^53 - 1) ... (2^53 - 1)`.
@Suite struct TLInt53Tests {
  static let maxRaw: Int64 = 9_007_199_254_740_991

  @Test("the bounds are the JS safe-integer range")
  func bounds() {
    #expect(TLInt53.max.rawValue == Self.maxRaw)
    #expect(TLInt53.min.rawValue == -Self.maxRaw)
    #expect(TLInt53.validRange == (-Self.maxRaw)...Self.maxRaw)
  }

  @Test("in-range values are accepted, out-of-range rejected")
  func validation() {
    #expect(TLInt53(rawValue: 0) != nil)
    #expect(TLInt53(rawValue: Self.maxRaw)?.rawValue == Self.maxRaw)
    #expect(TLInt53(rawValue: -Self.maxRaw)?.rawValue == -Self.maxRaw)
    // Just past either edge of the safe range is rejected.
    #expect(TLInt53(rawValue: Self.maxRaw + 1) == nil)
    #expect(TLInt53(rawValue: -Self.maxRaw - 1) == nil)
    #expect(TLInt53(rawValue: Int64.max) == nil)
    #expect(TLInt53(rawValue: Int64.min) == nil)
  }

  @Test("isValid matches the range")
  func isValid() {
    #expect(TLInt53.isValid(Self.maxRaw))
    #expect(!TLInt53.isValid(Self.maxRaw + 1))
    #expect(TLInt53.isValid(0))
  }

  @Test("the BinaryInteger init rejects values too wide for an Int53")
  func fromBinaryInteger() {
    #expect(TLInt53(42 as Int32)?.rawValue == 42)
    #expect(TLInt53(UInt64.max) == nil)
    #expect(TLInt53(UInt64(Self.maxRaw))?.rawValue == Self.maxRaw)
    #expect(TLInt53(UInt64(Self.maxRaw) + 1) == nil)
  }

  @Test("validating throws RangeError out of range")
  func validatingThrows() throws {
    #expect(try TLInt53(validating: 6).rawValue == 6)
    #expect(throws: TLInt53.RangeError.self) {
      try TLInt53(validating: Self.maxRaw + 1)
    }
  }

  @Test("clamping pins to the nearest bound")
  func clamping() {
    #expect(TLInt53(clamping: Self.maxRaw + 1000) == .max)
    #expect(TLInt53(clamping: -Self.maxRaw - 1000) == .min)
    #expect(TLInt53(clamping: 6).rawValue == 6)
  }

  @Test("integer literals build constants directly")
  func integerLiteral() {
    let bot: TLInt53 = 6
    #expect(bot.rawValue == 6)
    let user: TLInt53 = 888_014_056_99
    #expect(user.rawValue == 88_801_405_699)
  }

  @Test("Comparable and Hashable behave like the underlying Int64")
  func comparableHashable() {
    #expect((TLInt53(rawValue: 3)!) < (TLInt53(rawValue: 10)!))
    let set: Set<TLInt53> = [6, 6, 7]
    #expect(set.count == 2)
    #expect([3 as TLInt53, 1, 2].sorted().map(\.rawValue) == [1, 2, 3])
  }

  @Test("Codable round-trips as a bare Int64")
  func codable() throws {
    let value: TLInt53 = 88_801_405_699
    let data = try JSONEncoder().encode(value)
    // Encodes as a bare number, identical to the Int64 it stands in for.
    #expect(String(data: data, encoding: .utf8) == "88801405699")
    #expect(try JSONDecoder().decode(TLInt53.self, from: data) == value)
  }

  @Test("decoding an out-of-range value fails")
  func decodingRejectsOutOfRange() {
    let data = Data("9007199254740992".utf8)  // 2^53, one past the max
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(TLInt53.self, from: data)
    }
  }
}
