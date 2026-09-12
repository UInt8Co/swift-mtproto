import Crypto
import CryptoExtras

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The cryptographic core of two-step verification (2FA): SRP-6a over a 2048-bit
/// group, i.e. Telegram's
/// `passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow`, per
/// <https://core.telegram.org/api/srp>.
///
/// Every function here is pure — the only entropy is the caller-supplied secret
/// `b` or `a` — so all of it is known-answer testable.
///
/// The group (`p`, `g`) is a ``Group`` value rather than a constant, so a
/// deployment can configure or rotate it. Naming follows the spec: `salt1` is the
/// client salt (extended with 32 random bytes when a password is set), `salt2` the
/// server salt, and every group element is 256 bytes big-endian (``size``).
public enum SRP {
  /// The group size in bytes (2048 bits).
  public static let size = 256

  /// An SRP group: the prime `p` and generator `g`, plus the values derived
  /// from them (`k = H(p | g)` and the padded byte forms) precomputed once.
  public struct Group: Sendable, Equatable {
    /// The prime `p`, big-endian — exactly 256 bytes.
    public let pBytes: Data
    /// The generator `g`, as it travels in `PasswordKdfAlgo.g`.
    public let g: Int32
    /// The prime as a big integer.
    public let p: BigUInt
    /// The generator as a big integer.
    let gBig: BigUInt
    /// `g`, big-endian, left-padded to 256 bytes — the form hashed into `k`/M1.
    let gBytes: Data
    /// `k := H(p | g)` (both 256-byte big-endian).
    let k: BigUInt

    /// Builds a group from a 256-byte big-endian prime and a generator. The
    /// prime is trusted (not re-validated); use a genuine safe 2048-bit prime.
    public init(pBytes: Data, g: Int32) {
      self.pBytes = pBytes
      self.g = g
      self.p = BigUInt(bigEndianBytes: pBytes)
      let gb = BigUInt(UInt32(g))
      self.gBig = gb
      let gPadded = gb.bigEndianBytes(byteCount: SRP.size)
      self.gBytes = gPadded
      self.k = BigUInt(bigEndianBytes: SRP.h(pBytes + gPadded))
    }

    /// Builds a group from a hex prime, rejecting anything but a 2048-bit value.
    public init?(primeHex: String, g: Int32) {
      let bytes = Data(hexBytes: primeHex)
      guard bytes.count == SRP.size, bytes.first != 0 else { return nil }
      self.init(pBytes: bytes, g: g)
    }

    /// The well-known 2048-bit safe prime Telegram uses for SRP and DH, with
    /// generator `g = 3` — the default group when none is configured.
    public static let telegram2048 = Group(pBytes: Data(hexBytes: telegram2048PrimeHex), g: 3)
  }

  static let telegram2048PrimeHex =
    "C71CAEB9C6B1C9048E6C522F70F13F73980D40238E3E21C14934D037563D930F"
    + "48198A0AA7C14058229493D22530F4DBFA336F6E0AC925139543AED44CCE7C37"
    + "20FD51F69458705AC68CD4FE6B6B13ABDC9746512969328454F18FAF8C595F64"
    + "2477FE96BB2A941D5BCD1D4AC8CC49880708FA9B378E3C4F3A9060BEE67CF9A4"
    + "A4A695811051907E162753B56B0F6B410DBA74D8A84B2A14B3144E0EF1284754"
    + "FD17ED950D5965B4B9DD46582DB1178D169C6BC465B0D6FF9CA3928FEF5B9AE4"
    + "E418FC15E83EBEA0F87FA9FF5EED70050DED2849F47BF959D956850CE929851F"
    + "0D8115F635B105EE2E4E15D04B2454BF6F4FADF034B10403119CD8E3B92FCC5B"

  // MARK: - Hashing primitives (spec §"Hashing")

  /// `H(data) := sha256(data)`.
  static func h(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
  /// `SH(data, salt) := H(salt | data | salt)`.
  static func sh(_ data: Data, _ salt: Data) -> Data { h(salt + data + salt) }

  /// `x := PH2(password, salt1, salt2)` — the 32-byte password hash (group-
  /// independent): `PH1 = SH(SH(password, salt1), salt2)`, then
  /// `x = SH(pbkdf2(sha512, PH1, salt1, 100000), salt2)`.
  public static func passwordHash(password: Data, salt1: Data, salt2: Data) -> Data {
    let ph1 = sh(sh(password, salt1), salt2)
    // PBKDF2-HMAC-SHA512, 100 000 rounds. `unsafeUncheckedRounds` bypasses the
    // 210k OWASP floor swift-crypto enforces — the iteration count is fixed by
    // the protocol, not a tunable of ours.
    let derived = try! KDF.Insecure.PBKDF2.deriveKey(
      from: ph1, salt: salt1, using: .sha512, outputByteCount: 64,
      unsafeUncheckedRounds: 100_000)
    let pbkdf2 = derived.withUnsafeBytes { Data($0) }
    return sh(pbkdf2, salt2)
  }

  // MARK: - Setting a password (the verifier)

  /// The SRP verifier `v := pow(g, x) mod p`, big-endian / 256 bytes — the
  /// value the client sends as `new_password_hash` and the server stores.
  public static func verifier(group: Group, passwordHash x: Data) -> Data {
    group.gBig.power(BigUInt(bigEndianBytes: x), modulus: group.p)
      .bigEndianBytes(byteCount: size)
  }

  // MARK: - Login challenge (server side)

  /// The server's public value `B := (k*v + pow(g, b)) mod p`, 256 bytes, where
  /// `v` is the stored verifier and `b` the fresh per-challenge server secret.
  public static func srpB(group: Group, verifier v: Data, serverSecret b: Data) -> Data {
    let vBig = BigUInt(bigEndianBytes: v)
    let gb = group.gBig.power(BigUInt(bigEndianBytes: b), modulus: group.p)
    let kv = (group.k * vBig) % group.p
    return ((kv + gb) % group.p).bigEndianBytes(byteCount: size)
  }

  /// Verifies a client's `inputCheckPasswordSRP`: recomputes the server proof
  /// `M2` from the stored verifier `v`, the challenge secret `b` and the salts,
  /// and constant-time compares it to the client's `M1`.
  ///
  /// Server session key (spec §"Server"): `S = pow(g_a * pow(v, u), b) mod p`,
  /// `M2 = H(H(p) xor H(g) | H(salt1) | H(salt2) | g_a | g_b | H(S))`. `g_a` is
  /// the client's `A` exactly as received (256 bytes); `g_b` the `B` we sent.
  public static func verifyClientProof(
    group: Group, salt1: Data, salt2: Data, verifier v: Data, serverSecret b: Data,
    a clientA: Data, m1: Data
  ) -> Bool {
    // Reject malformed wire values before allocating bignums or doing any
    // modular exponentiations. SRP hashes group elements padded to 2048 bits.
    guard clientA.count == size, m1.count == SHA256.byteCount else { return false }
    let p = group.p
    let aBig = BigUInt(bigEndianBytes: clientA)
    // Reject A outside (1, p-1): the spec/tdlib guard against the degenerate
    // values that would force a known session key.
    guard aBig > BigUInt(1), aBig < p - BigUInt(1) else { return false }

    let bBytes = srpB(group: group, verifier: v, serverSecret: b)
    let u = BigUInt(bigEndianBytes: h(clientA + bBytes))
    guard !u.isZero else { return false }

    let vBig = BigUInt(bigEndianBytes: v)
    // S = (A * v^u)^b mod p.
    let base = (aBig * vBig.power(u, modulus: p)) % p
    let s = base.power(BigUInt(bigEndianBytes: b), modulus: p)
    let kA = h(s.bigEndianBytes(byteCount: size))

    let m2 = h(
      xor(h(group.pBytes), h(group.gBytes)) + h(salt1) + h(salt2) + clientA + bBytes + kA)
    return MTProtoConstantTime.equals(m2, m1)
  }

  // MARK: - Helpers

  /// Byte-wise XOR of two equal-length buffers.
  static func xor(_ a: Data, _ b: Data) -> Data {
    var out = Data(count: a.count)
    for i in 0..<a.count { out[i] = a[a.startIndex + i] ^ b[b.startIndex + i] }
    return out
  }
}

extension Data {
  /// Parses a hex string (even length, no `0x`) into raw bytes.
  fileprivate init(hexBytes hex: String) {
    let chars = Array(hex.utf8)
    var bytes = [UInt8]()
    bytes.reserveCapacity(chars.count / 2)
    func nibble(_ c: UInt8) -> UInt8 {
      switch c {
      case 0x30...0x39: return c - 0x30
      case 0x61...0x66: return c - 0x61 + 10
      case 0x41...0x46: return c - 0x41 + 10
      default: return 0
      }
    }
    var i = 0
    while i + 1 < chars.count {
      bytes.append(nibble(chars[i]) << 4 | nibble(chars[i + 1]))
      i += 2
    }
    self = Data(bytes)
  }
}
