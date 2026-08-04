import Testing
import TLCoding

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// Patterns that `mtproto-gen-swift` relies on when emitting code from the
// official JSON schema. These mirror the exact shapes the generator produces.

// A schema field named with a Swift keyword (`default`, `static`, …) is
// emitted as a backticked property; `self` cannot be backticked in a
// memberwise initializer (the parameter shadows the instance), so the
// generator renames it to `self_`.
@TLObject(id: 0x1122_3344)
@TLFlagsEquatable
private struct KeywordFields: Equatable {
  @TLFlags var flags: UInt32 = 0
  @TLConditional("flags", bit: 0) var `default`: Bool = false
  var self_: Bool
  var `static`: Int64
}

// Constructors of a multi-constructor TL type, as the generator emits them.
@TLObject(id: 0x7f3b_18ea)
private struct InputPeerEmptyG: Equatable {}

@TLObject(id: 0xdde8_a54c)
private struct InputPeerUserG: Equatable {
  var userId: Int64
  var accessHash: Int64
}

// The wrapper enum the generator emits for a multi-constructor type:
// boxed encoding delegates to the payload struct; decoding switches on the
// constructor number and reads the payload bare.
@TLType
private indirect enum InputPeerG: Equatable {
  case inputPeerEmpty(InputPeerEmptyG)
  case inputPeerUser(InputPeerUserG)
}

// A struct holding the enum (boxed field), with conditionals — the common
// shape of generated constructors. Also exercises recursion through the
// indirect enum (`replyTo` below references the enclosing type's enum).
@TLObject(id: 0x0102_0304)
@TLFlagsEquatable
private struct MessageG: Equatable {
  @TLFlags var flags: UInt32 = 0
  @TLConditional("flags", bit: 1) var pinned: Bool = false
  var peer: InputPeerG
  @TLConditional("flags", bit: 0) var replyTo: MessageEnumG?
}

@TLType
private indirect enum MessageEnumG: Equatable {
  case message(MessageG)
}

// Namespaces are emitted as nested caseless enums under a root `TL` enum;
// the macros must expand on types nested inside namespace extensions.
enum TLRoot {
  enum Auth {}
}

extension TLRoot.Auth {
  @TLObject(id: 0x5e00_2502)
  struct SentCodeNested: Equatable {
    var phoneCodeHash: String
  }

  @TLType
  indirect enum SentCodeNestedType: Equatable {
    case sentCode(TLRoot.Auth.SentCodeNested)
  }
}

// An RPC method struct: `@TLObject(id:returning:)` adds the `TLFunction`
// conformance with the right `ReturnType`.
@TLObject(id: 0xa677_244f, returning: TLRoot.Auth.SentCodeNestedType.self)
private struct SendCodeG: Equatable, Sendable {
  var phoneNumber: String
}

// A generic `invokeWithLayer`-style wrapper: encode-only (`TLEncodable` +
// `TLFunction` but not `TLDecodable`), with conditional fields handled by
// the same flags machinery. Attribute arguments cannot reference `Query`,
// so the conformance and `ReturnType` are declared at the site.
@TLObject(id: 0xda9b_0d0d)
private struct InvokeWithLayerG<Query: TLFunction>: TLFunction, Sendable {
  typealias ReturnType = Query.ReturnType

  var layer: Int32
  var query: Query
}

@TLObject(id: 0xc1cd_5ea9)
private struct InitConnectionG<Query: TLFunction>: TLFunction, Sendable {
  typealias ReturnType = Query.ReturnType

  @TLFlags var flags: UInt32 = 0
  var apiId: Int32
  @TLConditional("flags", bit: 0) var proxy: Int64?
  var query: Query
}

@Suite("Generator emission patterns")
struct GeneratorPatternsTests {
  @Test func nestedNamespaceObjectRoundTrips() throws {
    let value = TLRoot.Auth.SentCodeNested(phoneCodeHash: "abc")
    let decoded = try TLRoot.Auth.SentCodeNested(tlData: value.tlSerialized())
    #expect(decoded == value)
  }

  @Test func keywordNamedFieldsRoundTrip() throws {
    let value = KeywordFields(default: true, self_: false, static: 99)
    let decoded = try KeywordFields(tlData: value.tlSerialized())
    // The raw bitfield is stored back on decode (flags == 1), so generated
    // code emits an Equatable that ignores @TLFlags fields; compare the
    // logical fields and the wire form here.
    #expect(decoded.`default` == true)
    #expect(decoded.self_ == false)
    #expect(decoded.`static` == 99)
    #expect(decoded.tlSerialized() == value.tlSerialized())
  }

  @Test func typeEnumRoundTripsBothConstructors() throws {
    let user = InputPeerG.inputPeerUser(InputPeerUserG(userId: 7, accessHash: -1))
    let empty = InputPeerG.inputPeerEmpty(InputPeerEmptyG())
    #expect(try InputPeerG(tlData: user.tlSerialized()) == user)
    #expect(try InputPeerG(tlData: empty.tlSerialized()) == empty)
  }

  @Test func typeEnumEncodesSingleConstructorNumber() throws {
    let empty = InputPeerG.inputPeerEmpty(InputPeerEmptyG())
    // Boxed form must be exactly the payload's constructor number, once.
    #expect(empty.tlSerialized() == Data([0xea, 0x18, 0x3b, 0x7f]))
    #expect(empty.tlConstructorID == 0x7f3b_18ea)
    #expect(InputPeerG.tlConstructorIDs == [0x7f3b_18ea, 0xdde8_a54c])
  }

  @Test func recursionThroughIndirectEnumRoundTrips() throws {
    let inner = MessageG(peer: .inputPeerEmpty(InputPeerEmptyG()))
    let outer = MessageG(
      pinned: true,
      peer: .inputPeerUser(InputPeerUserG(userId: 1, accessHash: 2)),
      replyTo: .message(inner)
    )
    let decoded = try MessageG(tlData: outer.tlSerialized())
    #expect(decoded.tlSerialized() == outer.tlSerialized())
    #expect(decoded.pinned == true)
    #expect(decoded.replyTo == .message(inner))
  }

  @Test func unknownConstructorThrows() {
    var reader = TLReader(Data([0xde, 0xad, 0xbe, 0xef]))
    #expect(throws: TLError.self) {
      _ = try InputPeerG(tlFrom: &reader)
    }
  }

  @Test func nestedTypeEnumRoundTrips() throws {
    let value = TLRoot.Auth.SentCodeNestedType.sentCode(.init(phoneCodeHash: "h"))
    let decoded = try TLRoot.Auth.SentCodeNestedType(tlData: value.tlSerialized())
    #expect(decoded == value)
  }

  @Test func functionCarriesReturnType() throws {
    // `ReturnType` is usable for decoding an RPC reply.
    let function = SendCodeG(phoneNumber: "+1555")
    let reply = TLRoot.Auth.SentCodeNestedType.sentCode(.init(phoneCodeHash: "h"))
    let decoded = try SendCodeG.ReturnType(tlData: reply.tlSerialized())
    #expect(decoded == reply)
    // And the function itself round-trips as a normal @TLObject.
    #expect(try SendCodeG(tlData: function.tlSerialized()) == function)
  }

  @Test func genericWrapperEncodesAsBoxedFunction() throws {
    let wrapped = InvokeWithLayerG(layer: 200, query: SendCodeG(phoneNumber: "+1555"))
    var writer = TLWriter()
    wrapped.tlEncode(to: &writer)

    var expected = TLWriter()
    expected.writeUInt32(0xda9b_0d0d)
    expected.writeInt32(200)
    SendCodeG(phoneNumber: "+1555").tlEncode(to: &expected)
    #expect(writer.data == expected.data)
  }

  @Test func genericWrapperWithConditionalFields() throws {
    let query = SendCodeG(phoneNumber: "+1555")

    var without = TLWriter()
    InitConnectionG(apiId: 4, query: query).tlEncode(to: &without)
    var expectedWithout = TLWriter()
    expectedWithout.writeUInt32(0xc1cd_5ea9)
    expectedWithout.writeUInt32(0)  // flags
    expectedWithout.writeInt32(4)
    query.tlEncode(to: &expectedWithout)
    #expect(without.data == expectedWithout.data)

    var with = TLWriter()
    InitConnectionG(apiId: 4, proxy: 9, query: query).tlEncode(to: &with)
    var expectedWith = TLWriter()
    expectedWith.writeUInt32(0xc1cd_5ea9)
    expectedWith.writeUInt32(1)  // flags.0
    expectedWith.writeInt32(4)
    expectedWith.writeInt64(9)
    query.tlEncode(to: &expectedWith)
    #expect(with.data == expectedWith.data)
  }
}

// MARK: - Synthesized members

// A struct that keeps its own initializer and `==`: `@TLObject` must leave both
// alone, so a hand-written type can still control its API surface. The custom
// initializer reorders/derives parameters and the custom `==` deliberately
// compares only `id`, both of which a synthesized member would contradict.
@TLObject(id: 0x4d15_e0f1)
private struct CustomMembers: Equatable {
  @TLFlags var flags: UInt32 = 0
  var id: Int64
  @TLConditional("flags", bit: 0) var note: String?

  init(note: String?) {
    self.id = Int64(note?.count ?? 0)
    self.note = note
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// A non-wire stored property still belongs to the type, so it stays an
// initializer parameter (defaulted from its own declaration) and takes part in
// equality — only `@TLFlags` bitfields are excluded.
@TLObject(id: 0x6b2c_9a34)
@TLFlagsEquatable
private struct OmittedMember: Equatable {
  @TLFlags var flags: UInt32 = 0
  @TLConditional("flags", bit: 2) var live: Bool = false
  var id: Int64
  @TLOmit var cached: Int = 42
}

@Suite("Synthesized members")
struct SynthesizedMemberTests {
  @Test func initializerHidesFlagsAndDefaultsConditionals() throws {
    // No `flags:` parameter exists — the bitfield is recomputed on encode — and
    // the conditional/presence fields default to absent.
    let bare = MessageG(peer: .inputPeerEmpty(InputPeerEmptyG()))
    #expect(bare.pinned == false)
    #expect(bare.replyTo == nil)
    #expect(bare.flags == 0)

    let full = MessageG(
      pinned: true, peer: .inputPeerEmpty(InputPeerEmptyG()),
      replyTo: .message(bare))
    #expect(full.pinned == true)
    #expect(full.replyTo != nil)
  }

  @Test func equalityIgnoresStoredFlagsBits() throws {
    let value = MessageG(pinned: true, peer: .inputPeerEmpty(InputPeerEmptyG()))
    // Decoding stores the raw bitfield read off the wire; the synthesized `==`
    // must still call the two values equal.
    let decoded = try MessageG(tlData: value.tlSerialized())
    #expect(decoded.flags != value.flags)
    #expect(decoded == value)
  }

  @Test func equalityStillDistinguishesLogicalFields() {
    let peer = InputPeerG.inputPeerEmpty(InputPeerEmptyG())
    #expect(MessageG(pinned: true, peer: peer) != MessageG(pinned: false, peer: peer))
  }

  @Test func handWrittenInitializerAndEqualityWin() {
    // The custom initializer derives `id`, which a synthesized memberwise init
    // would instead have taken as a parameter.
    let value = CustomMembers(note: "abcd")
    #expect(value.id == 4)
    // And the custom `==` compares `id` only, so differing notes are equal.
    var other = CustomMembers(note: "wxyz")
    other.note = "different"
    #expect(value == other)
  }

  @Test func omittedPropertyStaysAnInitializerParameter() throws {
    let defaulted = OmittedMember(id: 1)
    #expect(defaulted.cached == 42)
    let explicit = OmittedMember(live: true, id: 1, cached: 7)
    #expect(explicit.cached == 7)
    // Excluded from the wire, so it does not survive a round trip …
    #expect(try OmittedMember(tlData: explicit.tlSerialized()).cached == 42)
    // … but it is part of the type, so equality sees it.
    #expect(explicit != OmittedMember(live: true, id: 1))
  }
}

// A `@TLObject` struct that keeps its own `==` — the case that must keep
// working, including through a generic `Equatable` constraint. Attaching
// `@TLFlagsEquatable` to a type like this is a compile error, and `@TLObject`
// alone must not quietly take the operator over.
@TLObject(id: 0x2c8f_44a1)
private struct OwnEquality: Equatable, Sendable {
  @TLFlags var flags: UInt32 = 0
  @TLConditional("flags", bit: 0) var note: String?
  var id: Int64

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@Suite("Flags-aware equality")
struct FlagsEquatableTests {
  /// Forces dispatch through the `Equatable` witness rather than direct
  /// overload resolution — where a derived `==` would take over unnoticed.
  private func equalThroughWitness<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }

  @Test("@TLFlagsEquatable is the Equatable witness, not a derived memberwise ==")
  func generatedEqualityIsTheWitness() throws {
    let value = MessageG(pinned: true, peer: .inputPeerEmpty(InputPeerEmptyG()))
    let decoded = try MessageG(tlData: value.tlSerialized())
    // Decoding stores the raw bits, so a derived `==` would report unequal.
    #expect(decoded.flags != value.flags)
    #expect(decoded == value)
    #expect(equalThroughWitness(decoded, value))
  }

  @Test("@TLObject alone leaves a hand-written == as the Equatable witness")
  func handWrittenEqualitySurvives() {
    let a = OwnEquality(note: "a", id: 1)
    let b = OwnEquality(note: "b", id: 1)
    // The custom operator compares `id` only; both call paths must agree.
    #expect(a == b)
    #expect(equalThroughWitness(a, b))
    #expect(!equalThroughWitness(a, OwnEquality(note: "a", id: 2)))
  }
}
