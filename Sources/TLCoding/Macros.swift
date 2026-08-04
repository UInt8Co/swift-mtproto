// MARK: - @TLObject

/// Makes a `struct` or `enum` serializable to and from the MTProto (TL) binary
/// format, deriving the constructor number from the declaration.
///
/// A struct is one TL constructor whose fields are its stored properties; an
/// enum is a TL type with one constructor per case. See <doc:DefiningTLTypes>
/// and <doc:ConstructorNumbers>.
///
/// ```swift
/// @TLObject
/// struct User {
///   var id: Int32
///   var firstName: String
/// }
/// // TL: user id:int first_name:string = User  →  user#d23c81a3
/// ```
@attached(
  extension, conformances: TLConstructed, TLEncodable, TLDecodable,
  names: named(tlConstructorID), named(tlConstructorIDs),
  named(tlEncode), named(tlEncodeBare), named(init))
@attached(member, names: named(init))
public macro TLObject() = #externalMacro(module: "TLCodingMacros", type: "TLObjectMacro")

/// Like ``TLObject()``, with the constructor number taken from a TL schema
/// (e.g. `@TLObject(id: 0x05162463)` for `resPQ`).
@attached(
  extension, conformances: TLConstructed, TLEncodable, TLDecodable,
  names: named(tlConstructorID), named(tlConstructorIDs),
  named(tlEncode), named(tlEncodeBare), named(init))
@attached(member, names: named(init))
public macro TLObject(id: UInt32) = #externalMacro(module: "TLCodingMacros", type: "TLObjectMacro")

/// Like ``TLObject(id:)``, and marks the type a TL *function* whose boxed result
/// decodes as `Result`: the generated extension also conforms to ``TLFunction``.
///
/// A generic wrapper declares the conformance itself and gets an encoder only —
/// see <doc:DefiningTLTypes>.
///
/// ```swift
/// @TLObject(id: 0xa677244f, returning: Auth.SentCodeType.self)
/// struct SendCode { ... }
/// ```
@attached(
  extension, conformances: TLConstructed, TLEncodable, TLDecodable, TLFunction,
  names: named(tlConstructorID), named(tlConstructorIDs),
  named(tlEncode), named(tlEncodeBare), named(init), named(ReturnType))
@attached(member, names: named(init))
public macro TLObject<Result: TLDecodable & Sendable>(id: UInt32, returning: Result.Type) =
  #externalMacro(module: "TLCodingMacros", type: "TLObjectMacro")

/// Like ``TLObject()``, but hashes the given TL declaration, e.g.
/// `@TLObject(schema: "user id:int first_name:string = User")`.
///
/// An explicit `#xxxxxxxx` number and a trailing `;` in the string are ignored.
@attached(
  extension, conformances: TLConstructed, TLEncodable, TLDecodable,
  names: named(tlConstructorID), named(tlConstructorIDs),
  named(tlEncode), named(tlEncodeBare), named(init))
@attached(member, names: named(init))
public macro TLObject(schema: String) =
  #externalMacro(module: "TLCodingMacros", type: "TLObjectMacro")

// MARK: - @TLType

/// Makes an enum the boxed form of a TL type whose constructors are standalone
/// ``TLObject()`` structs, one per case.
///
/// Encoding writes the payload's boxed form; decoding dispatches on the
/// constructor number. Mark the enum `indirect` when constructors reference
/// their own type. See <doc:DefiningTLTypes>.
///
/// ```swift
/// @TLType
/// indirect enum InputPeerType: Equatable, Sendable {
///   case inputPeerEmpty(InputPeerEmpty)
///   case inputPeerUser(InputPeerUser)
/// }
/// ```
@attached(
  extension, conformances: TLEncodable, TLDecodable,
  names: named(tlConstructorIDs), named(tlConstructorID), named(tlEncode), named(init))
public macro TLType() = #externalMacro(module: "TLCodingMacros", type: "TLTypeMacro")

// MARK: - @TLCase

/// Assigns an explicit constructor number to one case of a ``TLObject()`` enum.
@attached(peer)
public macro TLCase(id: UInt32) = #externalMacro(module: "TLCodingMacros", type: "TLMarkerMacro")

/// Computes one ``TLObject()`` enum case's constructor number from the given TL
/// declaration.
@attached(peer)
public macro TLCase(schema: String) =
  #externalMacro(module: "TLCodingMacros", type: "TLMarkerMacro")

// MARK: - Field markers

/// Marks a `UInt32` stored property as a TL `#` (flags) bitfield.
///
/// The bits are recomputed from the ``TLConditional(bit:)`` fields on encode.
/// See <doc:ConditionalFields>.
@attached(peer)
public macro TLFlags() = #externalMacro(module: "TLCodingMacros", type: "TLMarkerMacro")

/// Marks a stored property as a TL conditional field (`name:flags.N?type`).
///
/// An `Optional` property is serialized only when present; a non-optional `Bool`
/// maps to `flags.N?true`, where the bit itself is the value. See
/// <doc:ConditionalFields>.
@attached(peer)
public macro TLConditional(bit: Int) =
  #externalMacro(module: "TLCodingMacros", type: "TLMarkerMacro")

/// Like ``TLConditional(bit:)``, referencing a named ``TLFlags()`` property —
/// for a type with more than one bitfield, e.g. `@TLConditional("flags2", bit: 0)`.
@attached(peer)
public macro TLConditional(_ flagsField: String, bit: Int) =
  #externalMacro(module: "TLCodingMacros", type: "TLMarkerMacro")

/// Serializes a field bare: a nested object without its constructor number, an
/// array as a bare vector. TL's `%Type` and lowercase `vector<…>`.
@attached(peer)
public macro TLBare() = #externalMacro(module: "TLCodingMacros", type: "TLMarkerMacro")

/// Serializes a vector field's *elements* bare, each without its own
/// constructor number — TL's `%`-prefixed element spelling, as in
/// `salts:vector<future_salt>`. Array fields only.
///
/// Combine with ``TLBare()`` for a bare vector of bare elements; see
/// <doc:WireFormat>.
@attached(peer)
public macro TLBareElements() = #externalMacro(module: "TLCodingMacros", type: "TLMarkerMacro")

/// Excludes a stored property from serialization. It must have a default value,
/// so decoding can initialize the type without it.
@attached(peer)
public macro TLOmit() = #externalMacro(module: "TLCodingMacros", type: "TLMarkerMacro")

// MARK: - @TLFlagsEquatable

/// Generates the `==` a ``TLObject()`` struct with a ``TLFlags()`` bitfield
/// needs: one that compares the logical fields and ignores the raw bits.
///
/// Attach it alongside ``TLObject()``. It is deliberately separate, and
/// declaring an `==` as well is an error — see <doc:ConditionalFields>.
@attached(member, names: named(==))
public macro TLFlagsEquatable() =
  #externalMacro(module: "TLCodingMacros", type: "TLFlagsEquatableMacro")
