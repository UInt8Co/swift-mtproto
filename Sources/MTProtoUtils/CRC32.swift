/// Standard CRC-32 (IEEE 802.3 / zlib `crc32` variant), the checksum behind TL
/// constructor numbers and the `full` transport framing.
///
/// One-shot via ``checksum(of:)-(some_Sequence<UInt8>)``, or incremental via
/// ``update(with:)`` / ``checksum`` — so a frame's checksum can accumulate across
/// non-contiguous regions.
public struct CRC32: Sendable, Equatable {
  /// The IEEE 802.3 reflected polynomial.
  @usableFromInline
  static let polynomial: UInt32 = 0xEDB8_8320

  /// 256-entry lookup table for the byte-at-a-time algorithm.
  @usableFromInline
  static let table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
      var crc = UInt32(i)
      for _ in 0..<8 {
        crc = (crc >> 1) ^ (polynomial & (0 &- (crc & 1)))
      }
      table[i] = crc
    }
    return table
  }()

  /// The running, un-finalized state. Starts at `0xFFFFFFFF`.
  @usableFromInline
  var state: UInt32 = 0xFFFF_FFFF

  /// Creates a fresh checksum with no bytes consumed.
  @inlinable
  public init() {}

  /// Feeds more bytes into the running checksum.
  @inlinable
  public mutating func update(with bytes: some Sequence<UInt8>) {
    var crc = state
    for byte in bytes {
      crc = (crc >> 8) ^ Self.table[Int((crc ^ UInt32(byte)) & 0xFF)]
    }
    state = crc
  }

  /// The finalized checksum of everything consumed so far. Reading it does not
  /// disturb the running state, so more bytes may still be appended.
  @inlinable
  public var checksum: UInt32 { ~state }

  /// Computes the CRC-32 of `bytes` in one call.
  @inlinable
  public static func checksum(of bytes: some Sequence<UInt8>) -> UInt32 {
    var crc = CRC32()
    crc.update(with: bytes)
    return crc.checksum
  }
}
