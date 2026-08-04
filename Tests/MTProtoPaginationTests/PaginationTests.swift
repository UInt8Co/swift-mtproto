import Testing

@testable import MTProtoPagination

@Suite("Pagination — limit clamping")
struct ClampedLimitTests {
  @Test("Clamps into min...max")
  func clampsRange() {
    #expect(Pagination.clampedLimit(50, max: 100) == 50)
    #expect(Pagination.clampedLimit(500, max: 100) == 100)
    #expect(Pagination.clampedLimit(0, max: 100) == 1)
    #expect(Pagination.clampedLimit(-5, max: 100) == 1)
    #expect(Pagination.clampedLimit(5, min: 10, max: 100) == 10)
  }

  @Test("Default variant treats 0/negative as the supplied default")
  func defaultVariant() {
    #expect(Pagination.clampedLimit(0, default: 100, max: 200) == 100)
    #expect(Pagination.clampedLimit(-1, default: 100, max: 200) == 100)
    #expect(Pagination.clampedLimit(50, default: 100, max: 200) == 50)
    #expect(Pagination.clampedLimit(999, default: 100, max: 200) == 200)
    #expect(Pagination.clampedLimit(0, default: 500, max: 200) == 200)  // default itself capped
  }
}

@Suite("Pagination — offset window")
struct PageTests {
  let items = Array(0..<10)  // [0,1,2,...,9]

  @Test("Slices a mid-list window")
  func midList() {
    #expect(Array(Pagination.page(items, offset: 2, limit: 3)) == [2, 3, 4])
  }

  @Test("Clamps a window that runs off the end")
  func runsOffEnd() {
    #expect(Array(Pagination.page(items, offset: 8, limit: 5)) == [8, 9])
  }

  @Test("Offset past the end yields empty")
  func offsetPastEnd() {
    #expect(Pagination.page(items, offset: 20, limit: 5).isEmpty)
  }

  @Test("Negative offset/limit are treated as zero")
  func negativesAreZero() {
    #expect(Array(Pagination.page(items, offset: -3, limit: 2)) == [0, 1])
    #expect(Pagination.page(items, offset: 2, limit: -1).isEmpty)
  }

  @Test("Empty input yields empty")
  func emptyInput() {
    #expect(Pagination.page([Int](), offset: 0, limit: 5).isEmpty)
  }
}

@Suite("Pagination — offset_id cursor")
struct AfterCursorTests {
  // Newest-first ordering, as message history is delivered.
  let items = [50, 40, 30, 20, 10]

  @Test("offsetId 0 returns the whole list")
  func fromTop() {
    #expect(Array(Pagination.after(items, offsetId: 0, id: { Int64($0) })) == items)
  }

  @Test("Returns elements strictly after the cursor")
  func afterCursor() {
    #expect(Array(Pagination.after(items, offsetId: 30, id: { Int64($0) })) == [20, 10])
  }

  @Test("Cursor at the last element yields empty")
  func cursorAtEnd() {
    #expect(Pagination.after(items, offsetId: 10, id: { Int64($0) }).isEmpty)
  }

  @Test("Unknown cursor (fell off the list) yields empty")
  func unknownCursor() {
    #expect(Pagination.after(items, offsetId: 999, id: { Int64($0) }).isEmpty)
  }
}
