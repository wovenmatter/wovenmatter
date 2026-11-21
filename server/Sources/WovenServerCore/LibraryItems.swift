import Foundation
import WovenLibrary
import WovenProtocol

/// The library page: files, photos and links from every chat in the library.
package func registerLibraryItems(_ router: inout Router, library: Library) {
  router.on(ListLibraryItems.self) { request, _ in
    let all = try await library.libraryItems()
    let search = request.search.trimmingCharacters(in: .whitespacesAndNewlines)
    var matching = all.filter { item in
      (request.machineIDs.map { $0.contains(item.agent.machineID) } ?? true)
        && (request.runtimes.map { $0.contains(item.agent.runtime) } ?? true)
        && (request.agents.map { $0.contains(item.agent) } ?? true)
        && (request.fromPerson.map { $0 == item.fromPerson } ?? true)
        && (request.kind.map { $0 == item.kind } ?? true)
        && (request.since.map { item.sentAt >= $0 } ?? true)
        && (request.until.map { item.sentAt < $0 } ?? true)
        && (search.isEmpty || [item.title, item.source, item.sessionTitle].contains { $0.localizedCaseInsensitiveContains(search) })
    }
    if !request.oldestFirst { matching.reverse() }
    let offset = max(0, request.offset), limit = min(max(1, request.limit), 500)
    let page = Array(matching.dropFirst(offset).prefix(limit))
    var agents: [LibraryAgent] = []
    for item in all where !agents.contains(item.agent) { agents.append(item.agent) }
    return LibraryItemsPage(items: page, agents: agents, more: matching.count > offset + page.count)
  }
}
