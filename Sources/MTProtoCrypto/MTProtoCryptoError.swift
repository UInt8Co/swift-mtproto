#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Errors raised by the MTProto cryptographic primitives.
public enum MTProtoCryptoError: Error, Equatable, Sendable {
  /// An AES key was not exactly 32 bytes.
  case invalidKeySize(expected: Int, actual: Int)
  /// An AES-IGE IV was not exactly 32 bytes.
  case invalidIVSize(expected: Int, actual: Int)
  /// Data passed to a block cipher was not a multiple of the block size.
  case invalidBlockAlignment(length: Int)
  /// An RSA key could not be parsed from its serialized form.
  case invalidRSAKey(String)
  /// An RSA operation produced an out-of-range or malformed result.
  case rsaOperationFailed(String)
}
