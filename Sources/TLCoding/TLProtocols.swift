#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// MARK: - Core serialization protocols

/// A value that can be serialized into the MTProto (TL) binary format, in either
/// the boxed or the bare form. See <doc:WireFormat>.
public protocol TLEncodable {
  /// Appends the boxed form of `self` to `writer`.
  func tlEncode(to writer: inout TLWriter)
  /// Appends the bare form of `self` (no constructor prefix) to `writer`.
  func tlEncodeBare(to writer: inout TLWriter)
}

extension TLEncodable {
  /// By default the bare form equals the boxed one: a primitive is never really
  /// boxed, and a multi-constructor type cannot drop its constructor.
  public func tlEncodeBare(to writer: inout TLWriter) {
    tlEncode(to: &writer)
  }

  /// Serializes the boxed form of `self` into a standalone buffer.
  public func tlSerialized() -> Data {
    var writer = TLWriter()
    tlEncode(to: &writer)
    return writer.data
  }

  /// Serializes the bare form of `self` into a standalone buffer.
  public func tlSerializedBare() -> Data {
    var writer = TLWriter()
    tlEncodeBare(to: &writer)
    return writer.data
  }
}

/// A value that can be deserialized from the MTProto (TL) binary format.
public protocol TLDecodable {
  /// Reads the boxed form (constructor number + arguments) from `reader`.
  init(tlFrom reader: inout TLReader) throws
  /// Reads the bare form (arguments only) from `reader`.
  init(tlBareFrom reader: inout TLReader) throws
}

extension TLDecodable {
  /// By default the bare form equals the boxed form (see `TLEncodable`).
  public init(tlBareFrom reader: inout TLReader) throws {
    try self.init(tlFrom: &reader)
  }

  /// Decodes a boxed value from the start of `data`.
  public init(tlData data: Data) throws {
    var reader = TLReader(data)
    try self.init(tlFrom: &reader)
  }

  /// Decodes a bare value from the start of `data`.
  public init(tlBareData data: Data) throws {
    var reader = TLReader(data)
    try self.init(tlBareFrom: &reader)
  }
}

/// A value that is both TL-encodable and TL-decodable.
public typealias TLCodable = TLEncodable & TLDecodable

// MARK: - Single-constructor objects

/// A TL type with exactly one constructor — a `struct` annotated with
/// ``TLObject()``. The boxed forms come from the bare ones by prefixing, or
/// validating, the static constructor number.
public protocol TLConstructed: TLEncodable, TLDecodable {
  /// The 32-bit constructor number (CRC32 of the TL declaration).
  static var tlConstructorID: UInt32 { get }
}

extension TLConstructed {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeUInt32(Self.tlConstructorID)
    tlEncodeBare(to: &writer)
  }

  public init(tlFrom reader: inout TLReader) throws {
    let id = try reader.readUInt32()
    guard id == Self.tlConstructorID else {
      throw TLError.unexpectedConstructor(found: id, expected: [Self.tlConstructorID])
    }
    try self.init(tlBareFrom: &reader)
  }
}
