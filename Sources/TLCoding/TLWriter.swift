#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// An append-only binary buffer producing MTProto (TL) serialized data.
///
/// All values are written in little-endian byte order and the buffer is kept
/// 4-byte aligned by the TL `string`/`bytes` encoding rules.
public struct TLWriter: Sendable {
  /// The serialized bytes accumulated so far.
  public private(set) var data: Data

  public init() {
    self.data = Data()
  }

  public init(capacity: Int) {
    self.data = Data(capacity: capacity)
  }

  // MARK: Raw

  /// Appends raw bytes without any TL framing. The caller is responsible
  /// for keeping the buffer 4-byte aligned.
  public mutating func writeRawBytes(_ bytes: some Sequence<UInt8>) {
    data.append(contentsOf: bytes)
  }

  /// Appends raw data without any TL framing.
  public mutating func writeRawData(_ raw: Data) {
    data.append(raw)
  }

  // MARK: Fixed-width integers (`int`, `long`)

  public mutating func writeUInt32(_ value: UInt32) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
  }

  public mutating func writeInt32(_ value: Int32) {
    writeUInt32(UInt32(bitPattern: value))
  }

  public mutating func writeUInt64(_ value: UInt64) {
    writeUInt32(UInt32(truncatingIfNeeded: value))
    writeUInt32(UInt32(truncatingIfNeeded: value >> 32))
  }

  public mutating func writeInt64(_ value: Int64) {
    writeUInt64(UInt64(bitPattern: value))
  }

  // MARK: `double`

  public mutating func writeDouble(_ value: Double) {
    writeUInt64(value.bitPattern)
  }

  // MARK: `int128` / `int256`

  public mutating func writeInt128(_ value: TLInt128) {
    writeUInt64(value.low)
    writeUInt64(value.high)
  }

  public mutating func writeInt256(_ value: TLInt256) {
    writeUInt64(value.w0)
    writeUInt64(value.w1)
    writeUInt64(value.w2)
    writeUInt64(value.w3)
  }

  // MARK: `string` / `bytes`

  /// Appends a TL `string`/`bytes` value:
  /// - length ≤ 253: one length byte, payload, zero-padding to a multiple of 4;
  /// - length ≥ 254: the byte `0xFE`, a 3-byte little-endian length, payload,
  ///   zero-padding to a multiple of 4.
  public mutating func writeBytes(_ payload: Data) {
    let count = payload.count
    precondition(count < (1 << 24), "TL strings are limited to 2^24-1 bytes")
    let headerSize: Int
    if count <= 253 {
      data.append(UInt8(count))
      headerSize = 1
    } else {
      data.append(0xFE)
      data.append(UInt8(truncatingIfNeeded: count))
      data.append(UInt8(truncatingIfNeeded: count >> 8))
      data.append(UInt8(truncatingIfNeeded: count >> 16))
      headerSize = 4
    }
    data.append(payload)
    let padding = (4 - (headerSize + count) % 4) % 4
    for _ in 0..<padding {
      data.append(0)
    }
  }

  /// Appends a TL `string` value as the UTF-8 bytes of `string`.
  public mutating func writeString(_ string: String) {
    writeBytes(Data(string.utf8))
  }
}
