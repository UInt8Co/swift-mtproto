#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The `pq` challenge for the auth-key handshake: the server picks two distinct
/// primes `p < q` and sends their product `pq`; the client factorizes it back
/// into `p` and `q` (a deliberately cheap proof of work).
public struct PQChallenge: Sendable, Equatable {
  /// The smaller prime factor.
  public let p: UInt32
  /// The larger prime factor.
  public let q: UInt32
  /// The product `p * q`.
  public let pq: UInt64

  public init(p: UInt32, q: UInt32) {
    precondition(p < q)
    self.p = p
    self.q = q
    self.pq = UInt64(p) * UInt64(q)
  }

  /// Generates a challenge from two random ~31-bit primes.
  public static func random(using rng: inout some RandomNumberGenerator) -> PQChallenge {
    let a = randomPrime(using: &rng)
    var b = randomPrime(using: &rng)
    while b == a { b = randomPrime(using: &rng) }
    return PQChallenge(p: Swift.min(a, b), q: Swift.max(a, b))
  }

  public static func random() -> PQChallenge {
    var rng = SystemRandomNumberGenerator()
    return random(using: &rng)
  }

  /// The big-endian, minimal-length encoding of `pq` (the TL `bytes` payload).
  public var pqBytes: Data {
    var value = pq
    var bytes: [UInt8] = []
    while value > 0 {
      bytes.append(UInt8(truncatingIfNeeded: value))
      value >>= 8
    }
    if bytes.isEmpty { bytes = [0] }
    return Data(bytes.reversed())
  }

  /// The big-endian, minimal-length encoding of a 32-bit factor.
  public static func factorBytes(_ value: UInt32) -> Data {
    var v = value
    var bytes: [UInt8] = []
    while v > 0 {
      bytes.append(UInt8(truncatingIfNeeded: v))
      v >>= 8
    }
    if bytes.isEmpty { bytes = [0] }
    return Data(bytes.reversed())
  }

  /// Generates a random prime in `[2^30, 2^31)`.
  private static func randomPrime(using rng: inout some RandomNumberGenerator) -> UInt32 {
    while true {
      var candidate = UInt32.random(in: (1 << 30)..<(1 << 31), using: &rng)
      candidate |= 1  // odd
      if isPrime(candidate) { return candidate }
    }
  }

  /// Deterministic Miller–Rabin for 32-bit integers (witnesses {2,3,5,7}
  /// suffice below 3,215,031,751).
  public static func isPrime(_ n: UInt32) -> Bool {
    if n < 2 { return false }
    for small: UInt32 in [2, 3, 5, 7] {
      if n == small { return true }
      if n % small == 0 { return false }
    }
    var d = UInt64(n - 1)
    var r = 0
    while d % 2 == 0 {
      d /= 2
      r += 1
    }
    let nn = UInt64(n)
    for a: UInt64 in [2, 3, 5, 7] {
      var x = modPow(a % nn, d, nn)
      if x == 1 || x == nn - 1 { continue }
      var composite = true
      for _ in 0..<(r - 1) {
        x = (x &* x) % nn
        if x == nn - 1 {
          composite = false
          break
        }
      }
      if composite { return false }
    }
    return true
  }

  private static func modPow(_ base: UInt64, _ exponent: UInt64, _ modulus: UInt64) -> UInt64 {
    var result: UInt64 = 1
    var b = base % modulus
    var e = exponent
    while e > 0 {
      if e & 1 == 1 { result = (result &* b) % modulus }
      e >>= 1
      b = (b &* b) % modulus
    }
    return result
  }
}
