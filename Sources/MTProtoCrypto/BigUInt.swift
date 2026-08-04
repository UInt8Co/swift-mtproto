#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A minimal arbitrary-precision unsigned integer, just large enough for the
/// MTProto handshake: raw RSA (modular exponentiation) and the Diffie–Hellman
/// exchange (`g^b mod p`, `g_a^b mod p`).
///
/// Not a general-purpose or constant-time bignum. Limbs are little-endian base
/// 2³², normalized, so `0` is the empty array.
public struct BigUInt: Sendable, Equatable, Comparable {
  /// Base-2³² limbs, least-significant first, normalized (no trailing zeros).
  @usableFromInline var words: [UInt32]

  @inlinable init(words: [UInt32]) {
    self.words = words
    normalize()
  }

  public init() { self.words = [] }

  public init(_ value: UInt32) {
    self.words = value == 0 ? [] : [value]
  }

  @inlinable mutating func normalize() {
    while let last = words.last, last == 0 { words.removeLast() }
  }

  public var isZero: Bool { words.isEmpty }

  // MARK: - Big-endian byte conversion

  /// Parses a big-endian byte sequence (most-significant byte first), the form
  /// MTProto uses for `bytes`-encoded integers.
  public init(bigEndianBytes bytes: some Collection<UInt8>) {
    let array = Array(bytes)
    var words: [UInt32] = []
    words.reserveCapacity(array.count / 4 + 1)
    var index = array.count
    while index > 0 {
      let lo = index - 4
      var word: UInt32 = 0
      var shift: UInt32 = 0
      var i = index - 1
      while i >= Swift.max(lo, 0) {
        word |= UInt32(array[i]) << shift
        shift += 8
        if i == 0 { break }
        i -= 1
      }
      words.append(word)
      index -= 4
    }
    self.init(words: words)
  }

  /// The big-endian byte representation, left-padded with zeros to exactly
  /// `byteCount` bytes (truncating high zero bytes otherwise).
  public func bigEndianBytes(byteCount: Int? = nil) -> Data {
    var bytes: [UInt8] = []
    for word in words {
      bytes.append(UInt8(truncatingIfNeeded: word))
      bytes.append(UInt8(truncatingIfNeeded: word >> 8))
      bytes.append(UInt8(truncatingIfNeeded: word >> 16))
      bytes.append(UInt8(truncatingIfNeeded: word >> 24))
    }
    // `bytes` is now little-endian; trim high zeros and reverse.
    while let last = bytes.last, last == 0 { bytes.removeLast() }
    bytes.reverse()
    if let byteCount {
      if bytes.count < byteCount {
        bytes = [UInt8](repeating: 0, count: byteCount - bytes.count) + bytes
      } else if bytes.count > byteCount {
        bytes.removeFirst(bytes.count - byteCount)
      }
    }
    return Data(bytes)
  }

  /// The number of significant bits.
  public var bitWidth: Int {
    guard let last = words.last else { return 0 }
    return words.count * 32 - last.leadingZeroBitCount
  }

  // MARK: - Comparison

  public static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
    compare(lhs.words, rhs.words) < 0
  }

  /// Three-way comparison of two normalized little-endian limb arrays.
  @usableFromInline static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
    if a.count != b.count { return a.count < b.count ? -1 : 1 }
    var i = a.count - 1
    while i >= 0 {
      if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
      i -= 1
    }
    return 0
  }

  // MARK: - Add / subtract (on raw limb arrays)

  @usableFromInline static func addWords(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    var result: [UInt32] = []
    let n = Swift.max(a.count, b.count)
    result.reserveCapacity(n + 1)
    var carry: UInt64 = 0
    for i in 0..<n {
      let av = i < a.count ? UInt64(a[i]) : 0
      let bv = i < b.count ? UInt64(b[i]) : 0
      let sum = av + bv + carry
      result.append(UInt32(truncatingIfNeeded: sum))
      carry = sum >> 32
    }
    if carry != 0 { result.append(UInt32(carry)) }
    return result
  }

  /// `a - b`, requiring `a >= b`. Returns a normalized limb array.
  @usableFromInline static func subWords(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    var result: [UInt32] = []
    result.reserveCapacity(a.count)
    var borrow: Int64 = 0
    for i in 0..<a.count {
      let av = Int64(a[i])
      let bv = i < b.count ? Int64(b[i]) : 0
      var diff = av - bv - borrow
      if diff < 0 {
        diff += 0x1_0000_0000
        borrow = 1
      } else {
        borrow = 0
      }
      result.append(UInt32(truncatingIfNeeded: diff))
    }
    while let last = result.last, last == 0 { result.removeLast() }
    return result
  }

  public static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    BigUInt(words: addWords(lhs.words, rhs.words))
  }

  public static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    precondition(lhs >= rhs, "BigUInt subtraction underflow")
    return BigUInt(words: subWords(lhs.words, rhs.words))
  }

  // MARK: - Multiply

  @usableFromInline static func mulWords(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    if a.isEmpty || b.isEmpty { return [] }
    var result = [UInt32](repeating: 0, count: a.count + b.count)
    for i in 0..<a.count {
      var carry: UInt64 = 0
      let ai = UInt64(a[i])
      for j in 0..<b.count {
        let idx = i + j
        let cur = UInt64(result[idx]) + ai * UInt64(b[j]) + carry
        result[idx] = UInt32(truncatingIfNeeded: cur)
        carry = cur >> 32
      }
      var idx = i + b.count
      while carry != 0 {
        let cur = UInt64(result[idx]) + carry
        result[idx] = UInt32(truncatingIfNeeded: cur)
        carry = cur >> 32
        idx += 1
      }
    }
    return result
  }

  public static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    BigUInt(words: mulWords(lhs.words, rhs.words))
  }

  // MARK: - Division (Knuth Algorithm D)

  /// Quotient and remainder of `self / divisor`. Traps on division by zero.
  public func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
    precondition(!divisor.isZero, "BigUInt division by zero")
    let cmp = Self.compare(words, divisor.words)
    if cmp < 0 { return (BigUInt(), self) }
    if cmp == 0 { return (BigUInt(1), BigUInt()) }
    if divisor.words.count == 1 {
      let (q, r) = Self.divModSmall(words, divisor.words[0])
      return (BigUInt(words: q), BigUInt(r))
    }
    let (q, r) = Self.knuthDivMod(words, divisor.words)
    return (BigUInt(words: q), BigUInt(words: r))
  }

  public static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    lhs.quotientAndRemainder(dividingBy: rhs).remainder
  }

  public static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    lhs.quotientAndRemainder(dividingBy: rhs).quotient
  }

  /// Division by a single 32-bit limb.
  @usableFromInline static func divModSmall(_ u: [UInt32], _ v: UInt32) -> ([UInt32], UInt32) {
    var quotient = [UInt32](repeating: 0, count: u.count)
    var rem: UInt64 = 0
    var i = u.count - 1
    while i >= 0 {
      let cur = (rem << 32) | UInt64(u[i])
      quotient[i] = UInt32(cur / UInt64(v))
      rem = cur % UInt64(v)
      if i == 0 { break }
      i -= 1
    }
    while let last = quotient.last, last == 0 { quotient.removeLast() }
    return (quotient, UInt32(rem))
  }

  /// The classic base-2³² long division (Knuth TAOCP vol. 2, Algorithm D),
  /// for a divisor of at least two limbs. `u` and `v` are normalized
  /// little-endian limb arrays with `u >= v` and `v.count >= 2`.
  @usableFromInline static func knuthDivMod(_ u: [UInt32], _ v: [UInt32]) -> ([UInt32], [UInt32]) {
    let n = v.count
    let m = u.count - n
    let base: UInt64 = 0x1_0000_0000

    // D1: normalize so the divisor's top limb has its high bit set.
    let shift = v[n - 1].leadingZeroBitCount
    var vn = shiftLeft(v, bits: shift)
    if vn.count < n { vn.append(0) }  // keep exactly n limbs
    vn = Array(vn.prefix(n))
    var un = shiftLeft(u, bits: shift)
    // `un` must have exactly m + n + 1 limbs.
    while un.count < m + n + 1 { un.append(0) }

    var quotient = [UInt32](repeating: 0, count: m + 1)
    let vHigh = UInt64(vn[n - 1])
    let vSecond = UInt64(vn[n - 2])

    var j = m
    while j >= 0 {
      // D3: estimate qhat.
      let numerator = (UInt64(un[j + n]) << 32) | UInt64(un[j + n - 1])
      var qhat = numerator / vHigh
      var rhat = numerator % vHigh
      while qhat >= base || qhat * vSecond > (rhat << 32) | UInt64(un[j + n - 2]) {
        qhat -= 1
        rhat += vHigh
        if rhat >= base { break }
      }

      // D4: multiply and subtract qhat * v from un[j ..< j+n+1].
      var borrow: Int64 = 0
      var carry: UInt64 = 0
      for i in 0..<n {
        let product = qhat * UInt64(vn[i]) + carry
        carry = product >> 32
        let sub = Int64(un[j + i]) - borrow - Int64(UInt32(truncatingIfNeeded: product))
        if sub < 0 {
          un[j + i] = UInt32(truncatingIfNeeded: sub + Int64(base))
          borrow = 1
        } else {
          un[j + i] = UInt32(truncatingIfNeeded: sub)
          borrow = 0
        }
      }
      let subTop = Int64(un[j + n]) - borrow - Int64(carry)
      if subTop < 0 {
        un[j + n] = UInt32(truncatingIfNeeded: subTop + Int64(base))
        // D5/D6: qhat was one too large; add v back.
        qhat -= 1
        var addCarry: UInt64 = 0
        for i in 0..<n {
          let sum = UInt64(un[j + i]) + UInt64(vn[i]) + addCarry
          un[j + i] = UInt32(truncatingIfNeeded: sum)
          addCarry = sum >> 32
        }
        un[j + n] = UInt32(truncatingIfNeeded: UInt64(un[j + n]) + addCarry)
      } else {
        un[j + n] = UInt32(truncatingIfNeeded: subTop)
      }

      quotient[j] = UInt32(truncatingIfNeeded: qhat)
      if j == 0 { break }
      j -= 1
    }

    // D8: denormalize the remainder.
    var remainder = Array(un.prefix(n))
    remainder = shiftRight(remainder, bits: shift)
    while let last = quotient.last, last == 0 { quotient.removeLast() }
    while let last = remainder.last, last == 0 { remainder.removeLast() }
    return (quotient, remainder)
  }

  /// Logical left shift of a little-endian limb array by `bits` (0..<32).
  @usableFromInline static func shiftLeft(_ a: [UInt32], bits: Int) -> [UInt32] {
    if bits == 0 || a.isEmpty { return a }
    var result = [UInt32](repeating: 0, count: a.count + 1)
    for i in 0..<a.count {
      result[i] |= a[i] << bits
      result[i + 1] |= UInt32(UInt64(a[i]) >> (32 - bits))
    }
    while let last = result.last, last == 0 { result.removeLast() }
    return result
  }

  /// Logical right shift of a little-endian limb array by `bits` (0..<32).
  @usableFromInline static func shiftRight(_ a: [UInt32], bits: Int) -> [UInt32] {
    if bits == 0 || a.isEmpty { return a }
    var result = [UInt32](repeating: 0, count: a.count)
    for i in 0..<a.count {
      result[i] |= a[i] >> bits
      if i + 1 < a.count {
        result[i] |= UInt32(truncatingIfNeeded: UInt64(a[i + 1]) << (32 - bits))
      }
    }
    while let last = result.last, last == 0 { result.removeLast() }
    return result
  }

  // MARK: - Modular exponentiation

  /// `self^exponent mod modulus`, by left-to-right square-and-multiply.
  public func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
    precondition(!modulus.isZero, "modular exponentiation with zero modulus")
    if modulus == BigUInt(1) { return BigUInt() }
    var result = BigUInt(1)
    let base = self % modulus
    // Iterate exponent bits from most- to least-significant.
    let bits = exponent.bitWidth
    var i = bits - 1
    while i >= 0 {
      result = (result * result) % modulus
      let wordIndex = i / 32
      let bitIndex = i % 32
      if (exponent.words[wordIndex] >> bitIndex) & 1 == 1 {
        result = (result * base) % modulus
      }
      i -= 1
    }
    return result
  }
}
