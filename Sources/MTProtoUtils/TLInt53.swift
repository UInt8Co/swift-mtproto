/// A 64-bit integer confined to the range JavaScript represents exactly as a
/// `Number`: `-(2^53 - 1) ... (2^53 - 1)`.
///
/// Telegram entity ids — users, chats, channels — travel as a TL `long` but must
/// stay inside that range. Use this wherever such an id is held, and
/// ``rawValue`` only at the wire boundary, where `long` fields expect an `Int64`.
public struct TLInt53: RawRepresentable, Sendable, Hashable, Comparable, Codable {
  /// `Number.MAX_SAFE_INTEGER`, `2^53 - 1`.
  @usableFromInline
  static let maxRaw: Int64 = 9_007_199_254_740_991
  /// `Number.MIN_SAFE_INTEGER`, `-(2^53 - 1)`.
  @usableFromInline
  static let minRaw: Int64 = -9_007_199_254_740_991

  /// The largest representable value, `2^53 - 1`.
  public static let max = TLInt53(unchecked: maxRaw)
  /// The smallest representable value, `-(2^53 - 1)`.
  public static let min = TLInt53(unchecked: minRaw)
  /// The closed range of values a `TLInt53` may hold.
  public static let validRange: ClosedRange<Int64> = minRaw...maxRaw

  /// The underlying value, guaranteed to lie in ``validRange``.
  public let rawValue: Int64

  /// Whether `value` fits in the Int53 safe-integer range.
  @inlinable
  public static func isValid(_ value: Int64) -> Bool {
    minRaw <= value && value <= maxRaw
  }

  /// Builds a value without checking its range — only for the in-range static
  /// bounds above.
  private init(unchecked rawValue: Int64) {
    self.rawValue = rawValue
  }

  /// Creates a value, or `nil` when `rawValue` falls outside ``validRange``.
  @inlinable
  public init?(rawValue: Int64) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  /// Creates a value from any integer, or `nil` when it does not fit an Int53
  /// (either too wide for `Int64` or beyond the safe-integer range).
  @inlinable
  public init?(_ value: some BinaryInteger) {
    guard let raw = Int64(exactly: value), Self.isValid(raw) else { return nil }
    self.rawValue = raw
  }

  /// Creates a value, throwing ``RangeError`` when out of range. Use it at a
  /// trust boundary, so a bad id is rejected loudly rather than truncated.
  @inlinable
  public init(validating value: Int64) throws(RangeError) {
    guard Self.isValid(value) else { throw RangeError(value: value) }
    self.rawValue = value
  }

  /// Creates a value clamped into ``validRange``.
  @inlinable
  public init(clamping value: Int64) {
    self.rawValue = Swift.min(Swift.max(value, Self.minRaw), Self.maxRaw)
  }

  @inlinable
  public static func < (lhs: TLInt53, rhs: TLInt53) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// Thrown by ``init(validating:)`` for a value outside ``validRange``.
  public struct RangeError: Error, CustomStringConvertible {
    public let value: Int64
    public init(value: Int64) { self.value = value }
    public var description: String {
      "\(value) is outside the Int53 range \(TLInt53.minRaw)...\(TLInt53.maxRaw)"
    }
  }
}

extension TLInt53: ExpressibleByIntegerLiteral {
  /// Lets an id constant read as a plain literal (`let botID: TLInt53 = 6`). An
  /// out-of-range literal traps where it is written.
  @inlinable
  public init(integerLiteral value: Int64) {
    precondition(
      Self.isValid(value), "integer literal \(value) is outside the Int53 range")
    self.rawValue = value
  }
}

extension TLInt53: CustomStringConvertible {
  public var description: String { rawValue.description }
}

extension TLInt53 {
  /// Decodes a single `Int64`, re-checking the range — storage and JSON are no
  /// more trusted than the wire.
  @inlinable
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(validating: try container.decode(Int64.self))
  }

  /// Encodes as a bare `Int64`, so a `TLInt53` is wire/JSON-compatible with the
  /// `long` it stands in for.
  @inlinable
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
