#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// MARK: - TL `int` (32-bit)

extension Int32: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeInt32(self)
  }

  public init(tlFrom reader: inout TLReader) throws {
    self = try reader.readInt32()
  }
}

extension UInt32: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeUInt32(self)
  }

  public init(tlFrom reader: inout TLReader) throws {
    self = try reader.readUInt32()
  }
}

// MARK: - TL `long` (64-bit)

extension Int64: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeInt64(self)
  }

  public init(tlFrom reader: inout TLReader) throws {
    self = try reader.readInt64()
  }
}

extension UInt64: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeUInt64(self)
  }

  public init(tlFrom reader: inout TLReader) throws {
    self = try reader.readUInt64()
  }
}

/// `Int` is serialized as TL `long` (64-bit) regardless of platform width.
extension Int: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeInt64(Int64(self))
  }

  public init(tlFrom reader: inout TLReader) throws {
    let value = try reader.readInt64()
    guard let intValue = Int(exactly: value) else {
      throw TLError.invalidValue("TL long \(value) does not fit in Int on this platform")
    }
    self = intValue
  }
}

// MARK: - TL `double`

extension Double: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeDouble(self)
  }

  public init(tlFrom reader: inout TLReader) throws {
    self = try reader.readDouble()
  }
}

// MARK: - TL `string` / `bytes`

extension String: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeString(self)
  }

  public init(tlFrom reader: inout TLReader) throws {
    self = try reader.readString()
  }
}

extension Data: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeBytes(self)
  }

  public init(tlFrom reader: inout TLReader) throws {
    self = try reader.readBytes()
  }
}

// MARK: - `Bool`

/// `Bool` is a boxed TL type with two constructors:
/// `boolTrue#997275b5 = Bool;` and `boolFalse#bc799737 = Bool;`.
extension Bool: TLEncodable, TLDecodable {
  /// `boolTrue#997275b5`
  public static let tlTrueConstructorID: UInt32 = 0x9972_75b5
  /// `boolFalse#bc799737`
  public static let tlFalseConstructorID: UInt32 = 0xbc79_9737

  public func tlEncode(to writer: inout TLWriter) {
    writer.writeUInt32(self ? Self.tlTrueConstructorID : Self.tlFalseConstructorID)
  }

  public init(tlFrom reader: inout TLReader) throws {
    let id = try reader.readUInt32()
    switch id {
    case Self.tlTrueConstructorID:
      self = true
    case Self.tlFalseConstructorID:
      self = false
    default:
      throw TLError.unexpectedConstructor(
        found: id,
        expected: [Self.tlTrueConstructorID, Self.tlFalseConstructorID]
      )
    }
  }
}

// MARK: - `Vector t`

/// The constructor number of the polymorphic `vector {t:Type} # [ t ] = Vector t;`.
public let tlVectorConstructorID: UInt32 = 0x1cb5_c415

/// Arrays serialize as TL `Vector t`: boxed is `0x1cb5c415 count element*`, bare
/// drops the constructor.
///
/// The vector and its elements are independently bare or boxed — four
/// combinations, all four spelled in TL. ``tlEncode(to:)`` /
/// ``tlEncodeBare(to:)`` write elements in their canonical form; the
/// `…BareElements` / `…FullyBare` variants force them bare. See <doc:WireFormat>.
extension Array: TLEncodable where Element: TLEncodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeUInt32(tlVectorConstructorID)
    tlEncodeBare(to: &writer)
  }

  public func tlEncodeBare(to writer: inout TLWriter) {
    writer.writeInt32(Int32(count))
    for element in self {
      element.tlEncode(to: &writer)
    }
  }

  /// Boxed vector (`0x1cb5c415 count`) with **bare** elements (each via
  /// `tlEncodeBare`, no per-element constructor). TL `Vector<%t>`.
  public func tlEncodeBareElements(to writer: inout TLWriter) {
    writer.writeUInt32(tlVectorConstructorID)
    tlEncodeFullyBare(to: &writer)
  }

  /// Fully bare vector: no `0x1cb5c415` constructor and **bare** elements. TL's
  /// lowercase `vector<%t>` — e.g. `future_salts.salts`.
  public func tlEncodeFullyBare(to writer: inout TLWriter) {
    writer.writeInt32(Int32(count))
    for element in self {
      element.tlEncodeBare(to: &writer)
    }
  }
}

extension Array: TLDecodable where Element: TLDecodable {
  public init(tlFrom reader: inout TLReader) throws {
    let id = try reader.readUInt32()
    guard id == tlVectorConstructorID else {
      throw TLError.unexpectedConstructor(found: id, expected: [tlVectorConstructorID])
    }
    try self.init(tlBareFrom: &reader)
  }

  public init(tlBareFrom reader: inout TLReader) throws {
    try self.init(bareCountFrom: &reader, element: { try Element(tlFrom: &$0) })
  }

  /// Boxed vector (`0x1cb5c415 count`) of **bare** elements — the decode
  /// counterpart of `tlEncodeBareElements`.
  public init(tlBareElementsFrom reader: inout TLReader) throws {
    let id = try reader.readUInt32()
    guard id == tlVectorConstructorID else {
      throw TLError.unexpectedConstructor(found: id, expected: [tlVectorConstructorID])
    }
    try self.init(tlFullyBareFrom: &reader)
  }

  /// Fully bare vector (count + **bare** elements) — the decode counterpart of
  /// `tlEncodeFullyBare`.
  public init(tlFullyBareFrom reader: inout TLReader) throws {
    try self.init(bareCountFrom: &reader, element: { try Element(tlBareFrom: &$0) })
  }

  /// Shared core: a `count`-prefixed run of elements, each read by `element`.
  private init(
    bareCountFrom reader: inout TLReader,
    element: (inout TLReader) throws -> Element
  ) throws {
    try reader.beginDecodingComposite()
    defer { reader.endDecodingComposite() }
    let count = Int(try reader.readInt32())
    guard count >= 0 else {
      throw TLError.invalidValue("negative vector count \(count)")
    }
    try reader.consumeVectorElements(count)
    var result: [Element] = []
    // Bare empty constructors can occupy zero bytes. Bound both their total
    // work (above) and speculative allocation before validating any elements.
    result.reserveCapacity(Swift.min(count, reader.bytesRemaining / 4, 1024))
    for _ in 0..<count {
      result.append(try element(&reader))
    }
    self = result
  }
}
