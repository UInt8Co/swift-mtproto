#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A type-erased, already-serialized TL object: the `Object` pseudo-type that
/// `rpc_result`, `message`, `gzip_packed` and friends declare.
///
/// The concrete constructor is not knowable from the schema, so the raw boxed
/// bytes are kept verbatim. Encoding writes them as-is; decoding consumes *all
/// remaining* bytes — so an `Object` field is only well-defined as the last field
/// of its container, and the surrounding layer must delimit the input so "the
/// rest" is exactly one object.
public struct TLAnyObject: Hashable, Sendable {
  /// The raw boxed serialization of the wrapped object.
  public var boxedBytes: Data

  public init(boxedBytes: Data) {
    self.boxedBytes = boxedBytes
  }

  /// Wraps an already-`TLEncodable` value by serializing its boxed form.
  public init(_ value: some TLEncodable) {
    self.boxedBytes = value.tlSerialized()
  }

  /// Peeks the wrapped object's constructor number, or `nil` if it is empty
  /// or truncated.
  public var constructorID: UInt32? {
    guard boxedBytes.count >= 4 else { return nil }
    var reader = TLReader(boxedBytes)
    return try? reader.readUInt32()
  }

  /// Decodes the wrapped boxed object as a concrete `T`.
  public func decoded<T: TLDecodable>(as type: T.Type = T.self) throws -> T {
    try T(tlData: boxedBytes)
  }
}

extension TLAnyObject: TLEncodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeRawData(boxedBytes)
  }

  public func tlEncodeBare(to writer: inout TLWriter) {
    writer.writeRawData(boxedBytes)
  }
}

extension TLAnyObject: TLDecodable {
  public init(tlFrom reader: inout TLReader) throws {
    self.boxedBytes = try reader.readRawBytes(reader.bytesRemaining)
  }

  public init(tlBareFrom reader: inout TLReader) throws {
    self.boxedBytes = try reader.readRawBytes(reader.bytesRemaining)
  }
}
