/// The offset/limit paging rules of <https://corefork.telegram.org/api/offsets>.
///
/// ``page(_:offset:limit:)`` and ``after(_:offsetId:id:)`` work on a collection
/// already in memory; a database-backed list pages inside the query instead. See
/// <doc:MTProtoPagination>.
public enum Pagination {
  /// Clamps a wire `limit:int` into `min...max`. A `0` or negative limit clamps
  /// up to `min` — never "unlimited".
  public static func clampedLimit(_ raw: Int32, min: Int = 1, max: Int) -> Int {
    Swift.min(Swift.max(Int(raw), min), max)
  }

  /// Clamps a wire `limit:int`, treating `0` or negative as "use `default`" — for
  /// the RPCs where `limit: 0` means "the responder's choice".
  public static func clampedLimit(_ raw: Int32, default def: Int, max: Int) -> Int {
    raw > 0 ? Swift.min(Int(raw), max) : Swift.min(def, max)
  }

  /// A bounds-safe `offset`/`limit` window over a materialized list. An
  /// out-of-range offset or limit yields a short or empty slice, never a trap.
  public static func page<C: Collection>(_ items: C, offset: Int, limit: Int)
    -> C.SubSequence
  {
    let count = items.count
    let lower = Swift.min(Swift.max(offset, 0), count)
    let upper = Swift.min(lower + Swift.max(limit, 0), count)
    let start = items.index(items.startIndex, offsetBy: lower)
    let end = items.index(items.startIndex, offsetBy: upper)
    return items[start..<end]
  }

  /// The elements of a pre-ordered list *after* the one whose id is `offsetId` —
  /// cursor-based paging.
  ///
  /// `offsetId == 0` means "from the top". A cursor that has fallen off the list
  /// yields nothing, which is the protocol's "nothing newer to send".
  public static func after<C: Collection>(
    _ items: C, offsetId: Int64, id: (C.Element) -> Int64
  ) -> C.SubSequence {
    guard offsetId != 0 else { return items[items.startIndex..<items.endIndex] }
    guard let hit = items.firstIndex(where: { id($0) == offsetId }) else {
      return items[items.endIndex..<items.endIndex]
    }
    return items[items.index(after: hit)..<items.endIndex]
  }
}
