import TLCoding
import Testing

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@TLObject(id: 0x1020_3040)
private struct EmptyLimitElement: Equatable {}

@TLObject
private indirect enum RecursiveLimitObject: Equatable {
  case end
  @TLCase(id: 0x1020_3042)
  case next(RecursiveLimitObject)
}

@TLObject(id: 0x1020_3041)
private struct RecursiveLimitPayload: Equatable {
  var children: [RecursiveLimitType]
}

@TLType
private indirect enum RecursiveLimitType: Equatable {
  case node(RecursiveLimitPayload)
}

@Suite("Untrusted TL decoding limits")
struct DecodingLimitsTests {
  @Test func negativeRawLengthsDoNotMoveTheCursor() throws {
    var reader = TLReader([1, 2, 3, 4])
    for count in [-1, Int.min] {
      #expect(throws: TLError.self) { try reader.skip(count) }
      #expect(throws: TLError.self) { _ = try reader.readRawBytes(count) }
      #expect(reader.offset == 0)
    }
    #expect(try reader.readUInt32() == 0x0403_0201)
  }

  @Test func hugeLengthsThrowWithoutOverflow() {
    var reader = TLReader([1, 2, 3, 4])
    #expect(throws: TLError.self) { try reader.skip(Int.max) }
    #expect(throws: TLError.self) { _ = try reader.readRawBytes(Int.max) }
    #expect(reader.offset == 0)
  }

  @Test func emptyBareElementsRemainSupported() throws {
    var writer = TLWriter()
    writer.writeInt32(3)
    var reader = TLReader(writer.data, limits: .init(maximumVectorElements: 3))
    let values = try [EmptyLimitElement](tlFullyBareFrom: &reader)
    #expect(values.count == 3)
    #expect(reader.isAtEnd)
  }

  @Test func hugeZeroWidthVectorIsRejectedBeforeIteration() {
    var writer = TLWriter()
    writer.writeInt32(Int32.max)
    var reader = TLReader(writer.data)
    #expect(throws: TLError.self) { _ = try [EmptyLimitElement](tlFullyBareFrom: &reader) }
  }

  @Test func aggregateElementBudgetCoversSiblingVectors() throws {
    var writer = TLWriter()
    writer.writeInt32(3)
    writer.writeInt32(3)
    var reader = TLReader(writer.data, limits: .init(maximumVectorElements: 5))
    #expect(try [EmptyLimitElement](tlFullyBareFrom: &reader).count == 3)
    #expect(throws: TLError.self) { _ = try [EmptyLimitElement](tlFullyBareFrom: &reader) }
  }

  @Test func recursiveObjectEnumHonorsConfiguredDepth() throws {
    let value = RecursiveLimitObject.next(.next(.end))
    var reader = TLReader(value.tlSerialized(), limits: .init(maximumNestingDepth: 3))
    #expect(try RecursiveLimitObject(tlFrom: &reader) == value)
    reader = TLReader(value.tlSerialized(), limits: .init(maximumNestingDepth: 2))
    #expect(throws: TLError.self) { _ = try RecursiveLimitObject(tlFrom: &reader) }
  }

  @Test func recursiveTypeStructAndVectorShareDepthBudget() throws {
    let leaf = RecursiveLimitType.node(RecursiveLimitPayload(children: []))
    let value = RecursiveLimitType.node(RecursiveLimitPayload(children: [leaf]))
    var reader = TLReader(value.tlSerialized(), limits: .init(maximumNestingDepth: 6))
    #expect(try RecursiveLimitType(tlFrom: &reader) == value)
    reader = TLReader(value.tlSerialized(), limits: .init(maximumNestingDepth: 5))
    #expect(throws: TLError.self) { _ = try RecursiveLimitType(tlFrom: &reader) }
  }

  @Test func deeplyNestedWireInputThrowsInsteadOfExhaustingTheStack() {
    var writer = TLWriter()
    for _ in 0..<10_000 {
      writer.writeUInt32(RecursiveLimitObject.next(.end).tlConstructorID)
    }
    writer.writeUInt32(RecursiveLimitObject.end.tlConstructorID)
    #expect(throws: TLError.self) { _ = try RecursiveLimitObject(tlData: writer.data) }
  }

  @Test func depthUnwindsAfterFailureAndAcrossSiblingValues() throws {
    var writer = TLWriter()
    writer.writeUInt32(RecursiveLimitObject.next(.end).tlConstructorID)
    writer.writeUInt32(RecursiveLimitObject.end.tlConstructorID)
    writer.writeUInt32(RecursiveLimitObject.end.tlConstructorID)
    var reader = TLReader(writer.data, limits: .init(maximumNestingDepth: 1))
    #expect(throws: TLError.self) { _ = try RecursiveLimitObject(tlFrom: &reader) }
    #expect(try RecursiveLimitObject(tlFrom: &reader) == .end)
    #expect(try RecursiveLimitObject(tlFrom: &reader) == .end)
    #expect(reader.isAtEnd)
  }
}
