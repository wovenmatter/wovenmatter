import Foundation

/// When one part of a Page or Artifact last changed: the library replica that wrote it and
/// that replica's synchronization counter. A replica whose causal vector has reached `n`
/// for `r` has seen that change.
public struct NoteSyncDot: Codable, Equatable, Sendable {
  public var r: String?
  public var n: Int64
  public init(r: String?, n: Int64) { self.r = r; self.n = n }
  /// Written by the version that stores it: its origin and counter.
  static let current = NoteSyncDot(r: nil, n: 0)
  /// Made by a merge; the next local write takes it over.
  static let next = NoteSyncDot(r: nil, n: -1)
}

/// Causal clocks that let every library replica merge concurrent versions of a Page or an
/// Artifact the same way, without a shared ancestor.
///
/// A host stamps them on every write, from what changed since the stored version, and keeps
/// them as a trailing `~sync` member of the stored JSON. Readers outside the library store
/// never see them: `strip` removes them before content reaches an editor, a device or an
/// agent, and every write recomputes them, so a client cannot supply or damage them.
public enum NoteSync {
  static let marker = #","~sync":"#

  /// The stored content without its clocks, and the clocks.
  public static func split(_ content: String) -> (body: String, clock: [String: NoteSyncDot]?) {
    guard content.hasSuffix("}"), let range = content.range(of: marker, options: .backwards) else { return (content, nil) }
    let json = content[range.upperBound..<content.index(before: content.endIndex)]
    guard let clock = try? JSONDecoder().decode([String: NoteSyncDot].self, from: Data(json.utf8)) else { return (content, nil) }
    return (String(content[..<range.lowerBound]) + "}", clock)
  }

  public static func strip(_ content: String) -> String {
    content.hasSuffix("}") && content.contains(marker) ? split(content).body : content
  }

  static func attach(_ clock: [String: NoteSyncDot], to body: String) -> String {
    guard body.hasSuffix("}"), body.count > 2, body.first == "{" else { return body }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(clock) else { return body }
    return String(body.dropLast()) + marker + String(decoding: data, as: UTF8.self) + "}"
  }

  /// Pages and Artifacts merge between replicas. Notes and Sheets keep whole-document versions.
  static func mergeableDocument(_ body: String) -> NoteDocument? {
    // Cheap first: a Note or Sheet, however large, is not decoded on every save.
    guard body.hasPrefix("{"), body.contains(#""kind":"canvas""#) || body.contains(#""kind":"html""#),
          let data = body.data(using: .utf8),
          let document = try? JSONDecoder().decode(NoteDocument.self, from: data),
          [.canvas, .html].contains(document.kind) else { return nil }
    return document.normalized().materializedPage()
  }

  // MARK: Stamping a local write

  /// The content to store for a local write: `content` without any clocks it carried, plus
  /// clocks that keep the stored version's dot for every part this write left alone and mark
  /// every part it changed as written now. `previousRecord` is the origin and counter of the
  /// stored version's synchronization record, which owns its `current` dots.
  public static func stamp(content: String, title: String, folderID: String?,
                           previous: (content: String, title: String, folderID: String?)?,
                           previousRecord: NoteSyncDot?) -> String {
    let body = strip(content)
    guard let document = mergeableDocument(body) else { return body }
    let prior = previous.map { (split($0.content), $0.title, $0.folderID) }
    let priorDocument = prior.flatMap { mergeableDocument($0.0.body) }.flatMap { $0.kind == document.kind ? $0 : nil }
    let priorClock = prior?.0.clock
    func carried(_ key: String) -> NoteSyncDot? {
      // Content stored before clocks existed was all written by that record.
      guard let priorClock else { return previousRecord }
      guard let dot = priorClock[key] else { return nil }
      if dot.n == 0 { return previousRecord }
      return dot.n < 0 ? nil : dot
    }
    var clock: [String: NoteSyncDot] = [:]
    func record(_ key: String, unchanged: Bool) {
      clock[key] = unchanged ? (carried(key) ?? .current) : .current
    }
    record("title", unchanged: prior.map { $0.1 == title } ?? false)
    record("folder", unchanged: prior.map { $0.2 == folderID } ?? false)
    if document.kind == .canvas {
      let now = PageParts(document), before = priorDocument.map(PageParts.init)
      let moved = before.map { now.moved(since: $0) } ?? Set(now.order)
      for id in now.order {
        record("c:" + id, unchanged: before.map { $0.content(id) != nil && $0.content(id) == now.content(id) } ?? false)
        record("m:" + id, unchanged: before.map { $0.meta(id) != nil && $0.meta(id) == now.meta(id) } ?? false)
        record("p:" + id, unchanged: before?.has(id) == true && !moved.contains(id))
      }
      record("purpose", unchanged: priorDocument.map { $0.boardPurpose == document.boardPurpose } ?? false)
    } else {
      record("html", unchanged: priorDocument.map { $0.html == document.html } ?? false)
      record("doc", unchanged: priorDocument.map { $0.artifactRest == document.artifactRest } ?? false)
      for (key, entry) in document.artifactState ?? [:] {
        record("s:" + key, unchanged: priorDocument?.artifactState?[key] == entry)
      }
    }
    return attach(clock, to: body)
  }

  // MARK: Merging concurrent versions

  /// One stored version of a note, as a synchronization record carries it.
  public struct Version: Sendable {
    public var content: String, title: String, folderID: String?
    public var origin: String, clock: Int64, vector: [String: Int64]
    public init(content: String, title: String, folderID: String?, origin: String, clock: Int64, vector: [String: Int64]) {
      self.content = content; self.title = title; self.folderID = folderID
      self.origin = origin; self.clock = clock; self.vector = vector
    }
  }

  public struct Merged: Equatable, Sendable {
    public var content: String, title: String, folderID: String?
  }

  /// Combines concurrent versions of one Page or Artifact. `versions` must come in an order
  /// every replica agrees on, the deterministic winner first: the result then is the same on
  /// every replica. Changes to different parts all stay. When two versions changed the same
  /// Page component, the winner's stays in place and the other becomes a copy beside it,
  /// marked for review. Returns nil when the versions cannot merge this way, such as a Note,
  /// versions written before clocks existed, or two different Artifact codes; the caller then
  /// keeps whole-document versions.
  public static func merge(_ versions: [Version]) -> Merged? {
    guard versions.count > 1 else { return nil }
    var replicas: [Replica] = []
    for version in versions {
      guard let replica = Replica(version) else { return nil }
      replicas.append(replica)
    }
    guard Set(replicas.map(\.document.kind)).count == 1 else { return nil }
    var result = replicas[0]
    for local in replicas.dropFirst() {
      guard let merged = result.document.kind == .canvas ? mergePages(remote: result, local: local) : mergeArtifacts(remote: result, local: local)
      else { return nil }
      result = merged
    }
    guard (try? result.document.validateEditableShape()) != nil, let body = try? result.document.encoded() else { return nil }
    var clock: [String: NoteSyncDot] = [:]
    for (key, dot) in result.dots { clock[key] = dot ?? .next }
    return Merged(content: attach(clock, to: body), title: result.title, folderID: result.folderID)
  }

  /// A version with every dot resolved; `nil` dots were made by a merge and no replica has seen them.
  struct Replica {
    var document: NoteDocument
    var title: String
    var folderID: String?
    var dots: [String: NoteSyncDot?]
    var vector: [String: Int64]

    init(document: NoteDocument, title: String, folderID: String?, dots: [String: NoteSyncDot?], vector: [String: Int64]) {
      self.document = document; self.title = title; self.folderID = folderID; self.dots = dots; self.vector = vector
    }

    init?(_ version: Version) {
      let parts = NoteSync.split(version.content)
      guard let clock = parts.clock, let document = mergeableDocument(parts.body) else { return nil }
      let own = NoteSyncDot(r: version.origin, n: version.clock)
      self.init(document: document, title: version.title, folderID: version.folderID,
                dots: clock.mapValues { Optional($0.n <= 0 ? own : $0) }, vector: version.vector)
    }

    func dot(_ key: String) -> NoteSyncDot? { dots[key] ?? nil }
    /// Whether this version already includes that change.
    func saw(_ dot: NoteSyncDot?) -> Bool {
      guard let dot, let replica = dot.r else { return false }
      return (vector[replica] ?? 0) >= dot.n
    }
    /// Whether `other`'s value for `key` is one this version has seen, and this version's is newer or the same.
    func supersedes(_ other: Replica, _ key: String) -> Bool { saw(other.dot(key)) }
  }

  /// Which version's value stands for one part, decided from what each version has seen.
  private enum Side { case remote, local, concurrent }
  private static func side(_ key: String, remote: Replica, local: Replica) -> Side {
    if remote.supersedes(local, key) { return .remote }
    if local.supersedes(remote, key) { return .local }
    return .concurrent
  }

  private static func joined(_ a: [String: Int64], _ b: [String: Int64]) -> [String: Int64] {
    a.merging(b) { max($0, $1) }
  }

  private static func rowFields(remote: Replica, local: Replica) -> (title: String, folderID: String?, dots: [String: NoteSyncDot?]) {
    var dots: [String: NoteSyncDot?] = [:]
    let title = side("title", remote: remote, local: local) == .local ? local : remote
    let folder = side("folder", remote: remote, local: local) == .local ? local : remote
    dots["title"] = title.dot("title"); dots["folder"] = folder.dot("folder")
    return (title.title, folder.folderID, dots)
  }

  // MARK: Pages

  /// Derives the common ancestor each component implies from the two versions' clocks, then
  /// runs the ordinary three-way Page merge with it.
  private static func mergePages(remote: Replica, local: Replica) -> Replica? {
    let r = PageParts(remote.document), l = PageParts(local.document)
    var order: [String] = []
    var listed = Set<String>()
    for id in r.order + l.order where listed.insert(id).inserted { order.append(id) }

    var base = remote.document
    var blocks: [NoteBlock] = [], nodes: [String: PageNode] = [:], items: [String: BoardItem] = [:]
    var canvas: [String: CanvasCardPlacement] = [:]
    var conflicts = Set<String>(), positions = Set<String>()
    var localContent = Set<String>(), localMeta = Set<String>()
    func include(id: String, content: PageParts, meta: PageParts, parent: String?, sentinel: Bool = false) {
      blocks.append(sentinel ? .richText(NoteRichTextBlock(id: id, text: "\u{FFFF}")) : content.blocks[id]!)
      let isSection = r.isSection(id) || l.isSection(id)
      if isSection || parent != nil { nodes[id] = PageNode(parentID: parent, isSection: isSection) }
      if let placement = content.document.canvas?[id] { canvas[id] = placement }
      if let item = meta.document.boardItems?[id] { items[id] = item }
    }
    for id in order {
      switch (r.has(id), l.has(id)) {
      case (true, true):
        let contentSide = side("c:" + id, remote: remote, local: local)
        let metaSide = side("m:" + id, remote: remote, local: local)
        // The ancestor holds the older value, so the three-way merge keeps the newer one. A
        // concurrent change keeps the remote's in place and the local's as a copy.
        if contentSide == .local { localContent.insert(id) }
        if metaSide == .local { localMeta.insert(id) }
        if contentSide == .concurrent, r.content(id) != l.content(id) { conflicts.insert(id) }
        if metaSide == .concurrent, r.meta(id) != l.meta(id) { conflicts.insert(id) }
        let placeLocal = side("p:" + id, remote: remote, local: local) == .local
        if placeLocal { positions.insert(id) }
        include(id: id, content: contentSide == .local ? r : l, meta: metaSide == .local ? r : l,
                parent: placeLocal ? r.parent(id) : l.parent(id))
      case (false, true):
        // Every part of it seen by the remote: the remote removed it. Some parts seen: the
        // remote removed it while this side changed it, and the change stays.
        let seen = ["c:", "m:", "p:"].map { remote.saw(local.dot($0 + id)) }
        if seen.allSatisfy({ $0 }) { include(id: id, content: l, meta: l, parent: l.parent(id)) }
        else if seen.contains(true) { include(id: id, content: l, meta: l, parent: l.parent(id), sentinel: true) }
      case (true, false):
        let seen = ["c:", "m:", "p:"].map { local.saw(remote.dot($0 + id)) }
        if seen.allSatisfy({ $0 }) { include(id: id, content: r, meta: r, parent: r.parent(id)) }
        else if seen.contains(true) { include(id: id, content: r, meta: r, parent: r.parent(id), sentinel: true) }
      case (false, false): break
      }
    }
    base.blocks = blocks
    base.pageNodes = nodes
    base.canvas = canvas.isEmpty ? nil : canvas
    base.boardItems = items.isEmpty ? nil : items
    switch side("purpose", remote: remote, local: local) {
    case .remote: base.boardPurpose = local.document.boardPurpose
    case .local: base.boardPurpose = remote.document.boardPurpose
    case .concurrent: base.boardPurpose = remote.document.boardPurpose == local.document.boardPurpose ? local.document.boardPurpose : "\u{FFFF}"
    }

    guard var merged = try? NoteDocument.mergeReplicaPage(base: base, local: local.document, remote: remote.document,
                                                          conflicts: conflicts, localPositions: positions) else { return nil }
    let copies = Set(merged.conflictCopyIDs)
    // Attribution follows the version whose change was kept.
    for id in localContent.union(localMeta) {
      guard let item = local.document.boardItems?[id], item.updatedBy != nil, merged.document.boardItems?[id] != nil else { continue }
      merged.document.boardItems?[id]?.updatedBy = item.updatedBy
      merged.document.boardItems?[id]?.updatedAt = item.updatedAt
    }

    let fields = rowFields(remote: remote, local: local)
    var dots = fields.dots
    for block in merged.document.blocks {
      let id = block.id
      guard !copies.contains(id) else { continue }
      let inRemote = r.has(id), inLocal = l.has(id)
      func pick(_ key: String, local useLocal: Bool) -> NoteSyncDot? {
        (inRemote && inLocal ? (useLocal ? local : remote) : (inRemote ? remote : local)).dot(key + id)
      }
      dots["c:" + id] = pick("c:", local: localContent.contains(id))
      dots["m:" + id] = pick("m:", local: localMeta.contains(id))
      dots["p:" + id] = pick("p:", local: positions.contains(id))
    }
    dots["purpose"] = (side("purpose", remote: remote, local: local) == .local ? local : remote).dot("purpose")
    return Replica(document: merged.document, title: fields.title, folderID: fields.folderID, dots: dots,
                   vector: joined(remote.vector, local.vector))
  }

  // MARK: Artifacts

  /// Saved inputs merge key by key. The Artifact's code and anything else in it merge only
  /// when one version already includes the other's; two different concurrent codes do not.
  private static func mergeArtifacts(remote: Replica, local: Replica) -> Replica? {
    var document = remote.document
    var dots = rowFields(remote: remote, local: local).dots
    for key in ["html", "doc"] {
      let differs = key == "html" ? remote.document.html != local.document.html
        : remote.document.artifactRest != local.document.artifactRest
      switch side(key, remote: remote, local: local) {
      case .local:
        if key == "html" { document.html = local.document.html } else { document = local.document.replacingArtifactRest(of: document) }
        dots[key] = local.dot(key)
      case .concurrent where differs: return nil
      default: dots[key] = remote.dot(key)
      }
    }
    let remoteState = remote.document.artifactState ?? [:], localState = local.document.artifactState ?? [:]
    var state: [String: ArtifactStateEntry] = [:]
    for key in Set(remoteState.keys).union(localState.keys).sorted() {
      let id = "s:" + key
      switch (remoteState[key], localState[key]) {
      case let (r?, l?):
        if r == l { state[key] = r; dots[id] = remote.dot(id); continue }
        switch side(id, remote: remote, local: local) {
        case .remote: state[key] = r; dots[id] = remote.dot(id)
        case .local: state[key] = l; dots[id] = local.dot(id)
        case .concurrent:
          // Both changed one key: the higher version stands, then the winner's. Its version
          // moves past both, so a writer holding either one sees the change.
          var kept = l.version > r.version ? l : r
          kept.version = max(l.version, r.version) + 1
          state[key] = kept; dots[id] = (l.version > r.version ? local : remote).dot(id)
        }
      case let (r?, nil):
        if !local.saw(remote.dot(id)) { state[key] = r; dots[id] = remote.dot(id) }
      case let (nil, l?):
        if !remote.saw(local.dot(id)) { state[key] = l; dots[id] = local.dot(id) }
      case (nil, nil): break
      }
    }
    document.artifactState = state.isEmpty ? nil : state
    let fields = rowFields(remote: remote, local: local)
    return Replica(document: document, title: fields.title, folderID: fields.folderID, dots: dots,
                   vector: joined(remote.vector, local.vector))
  }
}

public extension NoteDocument {
  /// Merges a client's Artifact, saved after another device changed it, into the stored
  /// version. Saved inputs merge key by key; when both changed one key, the higher version
  /// stands, then the stored one, and its version moves past both. The code and the rest of
  /// the Artifact merge only when one side left them alone. Nil keeps both whole versions.
  static func mergeClientArtifact(base: NoteDocument, local: NoteDocument, remote: NoteDocument) -> NoteDocument? {
    guard base.kind == .html, local.kind == .html, remote.kind == .html else { return nil }
    func pick<T: Equatable>(_ b: T, _ l: T, _ r: T) -> T? { l == b || l == r ? r : (r == b ? l : nil) }
    guard var result = pick(base.artifactRest, local.artifactRest, remote.artifactRest),
          let html = pick(base.html, local.html, remote.html) else { return nil }
    result.html = html
    let b = base.artifactState ?? [:], l = local.artifactState ?? [:], r = remote.artifactState ?? [:]
    var state = r
    for key in Set(b.keys).union(l.keys).sorted() {
      let mine = l[key], theirs = r[key]
      guard mine?.value != b[key]?.value || (mine == nil) != (b[key] == nil), mine?.value != theirs?.value || (mine == nil) != (theirs == nil) else { continue }
      let theirsChanged = theirs?.value != b[key]?.value || (theirs == nil) != (b[key] == nil)
      guard var kept = theirsChanged && (theirs?.version ?? 0) >= (mine?.version ?? 0) ? theirs : mine else {
        state.removeValue(forKey: key); continue
      }
      kept.version = max(mine?.version ?? 0, theirs?.version ?? 0) + 1
      state[key] = kept
    }
    result.artifactState = state.isEmpty ? nil : state
    guard (try? result.validateArtifactState()) != nil else { return nil }
    return result
  }
}

private extension NoteDocument {
  /// Everything in an Artifact apart from its code and saved inputs.
  var artifactRest: NoteDocument {
    var copy = self; copy.html = ""; copy.artifactState = nil
    return copy
  }
  func replacingArtifactRest(of other: NoteDocument) -> NoteDocument {
    var copy = self; copy.html = other.html; copy.artifactState = other.artifactState
    return copy
  }
}

/// A Page's components split into what synchronization versions separately: content (the
/// writing, title and linked asset), metadata (role, task, review, links and change summary)
/// and placement (parent and order).
struct PageParts {
  struct Content: Equatable { var block: NoteBlock; var title: String?; var assetID: String?; var isSection: Bool }
  struct Meta: Equatable { var role: BoardItemRole; var task: BoardTask?; var review: BoardReviewState?; var sessions: [String]; var lastChange: String? }

  let document: NoteDocument
  let order: [String]
  let blocks: [String: NoteBlock]
  let children: [String?: [String]]

  init(_ document: NoteDocument) {
    self.document = document.materializedPage()
    order = self.document.blocks.map(\.id)
    blocks = Dictionary(self.document.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    children = self.document.pageChildMap()
  }

  func has(_ id: String) -> Bool { blocks[id] != nil }
  func isSection(_ id: String) -> Bool { document.pageNodes?[id]?.isSection == true }
  func parent(_ id: String) -> String? { document.pageNodes?[id]?.parentID }
  func content(_ id: String) -> Content? {
    guard let block = blocks[id] else { return nil }
    let value = document.pageComponentContent(of: block)
    return Content(block: value.block, title: value.title, assetID: value.assetID, isSection: isSection(id))
  }
  func meta(_ id: String) -> Meta? {
    guard let block = blocks[id] else { return nil }
    let value = document.pageComponentContent(of: block)
    return Meta(role: value.role, task: value.task, review: value.review, sessions: value.sessions, lastChange: value.lastChange)
  }

  /// Components placed somewhere new since `before`: a new parent, or out of their earlier
  /// order among siblings. Inserting or removing a neighbor moves nothing else.
  func moved(since before: PageParts) -> Set<String> {
    var result = Set<String>()
    for (parent, ids) in children {
      let index = Dictionary((before.children[parent] ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
      var kept: [(id: String, index: Int)] = []
      for id in ids {
        if let position = index[id], before.parent(id) == parent { kept.append((id, position)) } else { result.insert(id) }
      }
      result.formUnion(Set(kept.map(\.id)).subtracting(Self.increasing(kept)))
    }
    return result
  }

  /// The longest run that keeps its earlier order; whatever is outside it moved.
  static func increasing(_ values: [(id: String, index: Int)]) -> Set<String> {
    guard !values.isEmpty else { return [] }
    var tails: [Int] = []
    var previous = [Int](repeating: -1, count: values.count)
    for offset in values.indices {
      var low = 0, high = tails.count
      while low < high {
        let middle = (low + high) / 2
        if values[tails[middle]].index < values[offset].index { low = middle + 1 } else { high = middle }
      }
      if low > 0 { previous[offset] = tails[low - 1] }
      if low == tails.count { tails.append(offset) } else { tails[low] = offset }
    }
    var result = Set<String>()
    var cursor = tails.last ?? -1
    while cursor >= 0 { result.insert(values[cursor].id); cursor = previous[cursor] }
    return result
  }
}
