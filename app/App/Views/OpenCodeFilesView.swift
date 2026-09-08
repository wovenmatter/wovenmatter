import AppKit
import SwiftUI
import WovenMatterClient

struct OpenCodeFilesView: View {
    @Bindable var model: OpenCodeModel
    let conversationID: String
    @State private var path = ""
    @State private var search = ""
    @State private var entries: [OpenCodeValue] = []
    @State private var diffs: [OpenCodeValue] = []
    @State private var worktrees: [OpenCodeValue] = []
    @State private var content = ""
    @State private var previewImage: NSImage?
    @State private var branch = ""
    @State private var targetDirectory = ""
    @State private var failure: String?
    @State private var removeDirectory: String?
    @State private var diffMode = "working"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files on the OpenCode host").font(.headline)
            HStack {
                TextField("Directory relative to workspace", text: $path).onSubmit { list() }
                Button("Open Directory") { list() }
                Button("Parent") { path = (path as NSString).deletingLastPathComponent; list() }
            }
            HStack {
                TextField("Find files", text: $search)
                Button("Find") { run { entries = try await model.resource("fs/find", conversationID: conversationID, query: ["query": search, "limit": "100", "type": "file"])["data"].array } }
            }
            ForEach(entries, id: \.self) { entry in
                let entryPath = entry["path"].string ?? entry.string ?? ""
                HStack {
                Button { if entry["type"].text == "directory" { path = entryPath; list() } else { read(entryPath) } } label: {
                    Label(entryPath, systemImage: entry["type"].text == "directory" ? "folder" : "doc")
                }.buttonStyle(.plain)
                Spacer()
                if entry["type"].text != "directory" {
                    Button("Attach to Next Message") {
                        let root = model.snapshots[conversationID]?.info["location"]["directory"].text ?? model.directory
                        let absolute = entryPath.hasPrefix("/") ? entryPath : (root as NSString).appendingPathComponent(entryPath)
                        let file: OpenCodeValue = ["uri": .string(URL(fileURLWithPath: absolute).absoluteString), "name": .string((entryPath as NSString).lastPathComponent)]
                        if model.serverFiles[conversationID]?.contains(file) != true { model.serverFiles[conversationID, default: []].append(file) }
                    }
                }
                }
            }
            if let previewImage { Image(nsImage: previewImage).resizable().scaledToFit().frame(maxHeight: 280) }
            if !content.isEmpty {
                ScrollView(.horizontal) { Text(content).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 320)
            }
            Divider()
            HStack {
                Text("Changes").font(.headline)
                Picker("Compare", selection: $diffMode) { Text("Working tree").tag("working"); Text("Branch").tag("branch"); Text("Committed").tag("committed") }.frame(width: 180)
                TextField("Base ref (optional)", text: $branch)
                Button("Refresh Diff") { diff() }
            }
            ForEach(diffs, id: \.self) { item in
                DisclosureGroup(item["file"].text + "   +\(Int(item["additions"].number ?? 0)) −\(Int(item["deletions"].number ?? 0))") {
                    ScrollView(.horizontal) { Text(item["patch"].text).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                }
            }
            Divider()
            Text("Worktrees").font(.headline)
            ForEach(worktrees, id: \.self) { worktree in
                HStack {
                    Text(worktree["directory"].text).textSelection(.enabled); Spacer()
                    Button("Move Session Here") { run { _ = try await model.sessionCall(conversationID, "/move", method: "POST", body: ["directory": worktree["directory"]]) } }
                    Button("Remove…", role: .destructive) { removeDirectory = worktree["directory"].text }
                }
            }
            HStack {
                TextField("New branch", text: $branch)
                TextField("New worktree path on server", text: $targetDirectory)
                Button("Create Worktree") { run {
                    var body: OpenCodeValue = [:]
                    if !branch.isEmpty { body["branch"] = .string(branch) }
                    if !targetDirectory.isEmpty { body["directory"] = .string(targetDirectory) }
                    _ = try await model.resource("worktree", conversationID: conversationID, method: "POST", body: body)
                    try await reloadWorktrees()
                } }
            }
            Button("Refresh Worktrees") { run { _ = try await model.resource("worktree/refresh", conversationID: conversationID, method: "POST"); try await reloadWorktrees() } }
            if let failure { Text(failure).foregroundStyle(.red) }
        }.textFieldStyle(.roundedBorder).task { list(); diff(); run { try await reloadWorktrees() } }
        .confirmationDialog("Remove this worktree on the OpenCode host?", isPresented: Binding(get: { removeDirectory != nil }, set: { if !$0 { removeDirectory = nil } }), titleVisibility: .visible) {
            Button("Remove Worktree", role: .destructive) {
                if let directory = removeDirectory { run {
                    _ = try await model.resource("worktree", conversationID: conversationID, method: "DELETE", body: ["directory": .string(directory), "force": .bool(false)])
                    removeDirectory = nil; try await reloadWorktrees()
                } }
            }
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        model.perform { failure = nil; do { try await operation() } catch { failure = error.localizedDescription } }
    }
    private func list() { run { entries = try await model.resource("fs/list", conversationID: conversationID, query: ["path": path])["data"].array } }
    private func diff() { run {
        var query = ["mode": diffMode]; if !branch.isEmpty { query["base"] = branch }
        diffs = try await model.resource("vcs/diff", conversationID: conversationID, query: query)["data"].array
    } }
    private func reloadWorktrees() async throws { worktrees = try await model.resource("worktree", conversationID: conversationID)["data"].array }
    private func read(_ path: String) { run {
        guard let link = model.links[conversationID] else { return }
        let (bytes, mime) = try await model.coordinator.readFile(connectionID: link.connectionID, path: path, query: model.locationQuery(conversationID))
        previewImage = mime.hasPrefix("image/") ? NSImage(data: bytes) : nil
        content = previewImage == nil ? String(data: bytes, encoding: .utf8) ?? "Binary file (\(bytes.count) bytes)" : ""
    } }
}
