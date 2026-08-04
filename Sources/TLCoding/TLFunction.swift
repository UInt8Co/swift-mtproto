/// A TL *functional combinator* — an RPC request paired with the type its boxed
/// result decodes to. ``TLObject(id:returning:)`` generates the conformance.
///
/// An RPC layer sends `function.tlSerialized()` and decodes the reply as
/// `ReturnType`:
///
/// ```swift
/// func invoke<F: TLFunction>(_ function: F) async throws -> F.ReturnType {
///   let reply = try await transport.send(function.tlSerialized())
///   return try F.ReturnType(tlData: reply)
/// }
/// ```
public protocol TLFunction: TLEncodable, Sendable {
  /// The type the function's boxed result decodes to.
  associatedtype ReturnType: TLDecodable & Sendable
}
