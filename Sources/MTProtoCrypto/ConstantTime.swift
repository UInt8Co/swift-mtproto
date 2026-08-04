#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Comparisons of secret-dependent values, so response timing cannot become an
/// oracle.
public enum MTProtoConstantTime {
  /// Compares two buffers in time independent of *where* they first differ. The
  /// length is not secret: a mismatch returns `false` immediately.
  public static func equals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    var indexA = a.startIndex
    var indexB = b.startIndex
    while indexA < a.endIndex {
      difference |= a[indexA] ^ b[indexB]
      indexA = a.index(after: indexA)
      indexB = b.index(after: indexB)
    }
    return difference == 0
  }
}
