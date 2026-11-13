/// A TL *functional combinator* — an RPC request paired with the type its boxed
/// result decodes to. ``TLObject(id:returning:)`` generates the conformance.
///
/// The transport at the bottom of an RPC stack sends `function.tlSerialized()`
/// and decodes the reply as `ReturnType`; layers above it pass the typed
/// function and result through, so each value is encoded and decoded once:
///
/// ```swift
/// func invoke<F: TLFunction>(_ function: F) async throws -> F.ReturnType {
///   let reply = try await connection.send(function.tlSerialized())
///   return try F.ReturnType(tlData: reply)
/// }
/// ```
public protocol TLFunction: TLEncodable, Sendable {
  /// The type the function's boxed result decodes to.
  associatedtype ReturnType: TLDecodable & Sendable

  /// The method's TL name as written in the schema, namespace included —
  /// `"users.getUsers"`, `"invokeWithLayer"`, `"ping"`. For logs and
  /// diagnostics, without parsing the serialized request.
  static var tlMethodName: String { get }

  /// The function a chain of ``TLFunctionWrapper``s ultimately carries: `self`
  /// for a plain function, the innermost `query` for a wrapper, however deeply
  /// nested — `invokeWithLayer(initConnection(help.getConfig))` yields
  /// `help.getConfig`.
  var tlInnermostFunction: any TLFunction { get }
}

extension TLFunction {
  public var tlInnermostFunction: any TLFunction { self }
}

/// A function that wraps another query (`query:!X = X`), e.g. invokeWithLayer.
///
/// The wrapper's result is its query's result, and the query is reachable
/// without knowing the generic types through ``TLFunction/tlInnermostFunction``.
public protocol TLFunctionWrapper: TLFunction where ReturnType == Query.ReturnType {
  /// The wrapped function.
  associatedtype Query: TLFunction
  /// The wrapped query, itself possibly a wrapper.
  var query: Query { get }
}

extension TLFunctionWrapper {
  // The more specific default: it, not `TLFunction`'s, witnesses the
  // requirement for every wrapper, so the lookup recurses even through an
  // existential or a generic context.
  public var tlInnermostFunction: any TLFunction { query.tlInnermostFunction }
}
