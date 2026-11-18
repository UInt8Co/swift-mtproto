/// Which enum cases must be `indirect`.
///
/// Swift stores an enum's payloads and a struct's fields inline, so a value type
/// that contains itself — directly, through an `Optional`, or through other
/// structs and enums stored inline — has infinite size. An `Array` (a TL
/// `Vector`), `String`, `Data` or `TLAnyObject` keeps its contents on the heap
/// and ends the chain. A generated type enum is therefore only made recursive
/// by the cases whose payload struct leads back to the enum inline, and only
/// those are emitted `indirect`: every other case keeps its payload inline
/// instead of in a heap box.
///
/// The analysis builds the graph of generated value types — one node per type
/// enum and per constructor struct — with an edge for each inline reference:
/// enum → each case's payload struct, struct → the type of each plain or
/// conditional field that names a schema type. A case is `indirect` exactly when
/// its payload struct shares a strongly connected component with its enum.
/// Every cycle through an enum passes through such a case, so this breaks them
/// all. (A cycle of single-constructor structs alone cannot be broken by
/// `indirect` and never occurs in a valid schema.)
extension ResolvedSchema {
  /// The TL constructor names whose case in their type's enum must be
  /// `indirect`, over the types in ``types``. References to names outside
  /// ``types`` (e.g. declarations another module provides) are leaves: such a
  /// module cannot refer back to these declarations.
  func indirectCaseConstructors() -> Set<String> {
    // Nodes, numbered in schema order so the traversal is deterministic.
    var enumNode: [String: Int] = [:]  // TL type (multi-constructor) → node
    var structNode: [String: Int] = [:]  // TL constructor → node
    var nodeCount = 0
    for type in types {
      if type.swiftEnumName != nil {
        enumNode[type.tlName] = nodeCount
        nodeCount += 1
      }
      for constructor in type.constructors {
        structNode[constructor.tlName] = nodeCount
        nodeCount += 1
      }
    }
    let definitions = Dictionary(types.map { ($0.tlName, $0) }, uniquingKeysWith: { first, _ in first })

    /// The node a field naming `tlName` stores inline, resolved as
    /// ``baseResolver()`` does: a boxed type first, then a bare constructor.
    func referencedNode(_ tlName: String) -> Int? {
      if let type = definitions[tlName] {
        return type.swiftEnumName != nil
          ? enumNode[type.tlName] : structNode[type.constructors[0].tlName]
      }
      return structNode[tlName]
    }

    var edges = [[Int]](repeating: [], count: nodeCount)
    for type in types {
      if let node = enumNode[type.tlName] {
        edges[node] = type.constructors.map { structNode[$0.tlName]! }
      }
      for constructor in type.constructors {
        let node = structNode[constructor.tlName]!
        for field in constructor.fields {
          let value: TLValueType?
          switch field.kind {
          case .flagsBitfield: value = nil
          case .plain(let plain): value = plain
          case .conditional(_, _, let wrapped): value = wrapped  // `T?` is inline.
          }
          // Only a bare `.named` is inline; a `.vector` is heap-backed.
          if case .named(let tlName)? = value, let target = referencedNode(tlName) {
            edges[node].append(target)
          }
        }
      }
    }

    let component = Self.stronglyConnectedComponents(edges: edges)
    var result: Set<String> = []
    for type in types {
      guard let node = enumNode[type.tlName] else { continue }
      for constructor in type.constructors
      where component[structNode[constructor.tlName]!] == component[node] {
        result.insert(constructor.tlName)
      }
    }
    return result
  }

  /// Tarjan's algorithm, iterative so a deep schema cannot exhaust the stack.
  /// Returns each node's component id; nodes share an id exactly when they
  /// reach each other.
  static func stronglyConnectedComponents(edges: [[Int]]) -> [Int] {
    let count = edges.count
    var index = [Int](repeating: -1, count: count)
    var lowLink = [Int](repeating: 0, count: count)
    var onStack = [Bool](repeating: false, count: count)
    var component = [Int](repeating: -1, count: count)
    var stack: [Int] = []
    var nextIndex = 0
    var nextComponent = 0

    for root in 0..<count where index[root] == -1 {
      // Each frame is a node and the position of its next edge to visit.
      var frames: [(node: Int, edge: Int)] = [(root, 0)]
      index[root] = nextIndex
      lowLink[root] = nextIndex
      nextIndex += 1
      stack.append(root)
      onStack[root] = true

      while let frame = frames.last {
        let node = frame.node
        if frame.edge < edges[node].count {
          frames[frames.count - 1].edge += 1
          let next = edges[node][frame.edge]
          if index[next] == -1 {
            index[next] = nextIndex
            lowLink[next] = nextIndex
            nextIndex += 1
            stack.append(next)
            onStack[next] = true
            frames.append((next, 0))
          } else if onStack[next] {
            lowLink[node] = min(lowLink[node], index[next])
          }
          continue
        }
        frames.removeLast()
        if let parent = frames.last?.node {
          lowLink[parent] = min(lowLink[parent], lowLink[node])
        }
        if lowLink[node] == index[node] {
          while let member = stack.popLast() {
            onStack[member] = false
            component[member] = nextComponent
            if member == node { break }
          }
          nextComponent += 1
        }
      }
    }
    return component
  }
}
