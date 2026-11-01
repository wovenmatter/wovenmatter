import SwiftUI
import CompanionInference

/// A send or resume waiting for the user's decision. A send has not been
/// submitted, so its draft stays in the composer. A resume keeps its saved,
/// interrupted run unchanged. Neither makes a request until the user allows it.
struct DataSharingRequest: Identifiable, Equatable {
  var destination: DataSharingDestination
  var resume: Bool
  /// The chat the send or resume belongs to; nil for a chat not yet created.
  var conversationID: String?
  var id: String { destination.id }
}

extension CompanionModel {
  var dataSharingFile: URL? { executionDirectory?.appendingPathComponent("data-sharing.json") }
  /// An unreadable record fails closed: Quick Chat asks again instead of assuming permission.
  func loadDataSharing() {
    guard let dataSharingFile else { dataSharing = .init(); return }
    do { dataSharing = try DataSharingPermissions.load(from: dataSharingFile) }
    catch { dataSharing = .init(); errorMessage = "Saved data-sharing choices could not be read. Quick Chat will ask again before sending." }
  }
  /// Read at each request, so revoking in Settings stops the next request of a running chat.
  var dataSharingPolicy: DataSharingPolicy {
    DataSharingPolicy { [weak self] destination in
      guard let self else { return false }
      return await self.permitsSharing(destination)
    }
  }
  func permitsSharing(_ destination: DataSharingDestination) -> Bool { !fixture && dataSharing.permits(destination) }
  func setDataSharing(_ destination: DataSharingDestination, allowed: Bool) throws {
    guard let dataSharingFile else { throw DeviceExecutionError.unavailable("The device workspace could not be opened.") }
    var updated = dataSharing
    if allowed { updated.grant(destination) } else { updated.revoke(destination) }
    try updated.save(to: dataSharingFile)
    dataSharing = updated
    if allowed && destination == .exa { exaSharingDeclined.removeAll() }
  }
  /// The pinned endpoint for an existing chat, or the selected connection's for a new one.
  func inferenceDestination(for conversationID: String?, connection: InferenceConnection) -> DataSharingDestination? {
    if let conversationID, let record = executionRecords[conversationID] {
      let pinned = try? JSONDecoder().decode(InferenceModel.self, from: Data(record.modelJSON.utf8))
      return .inference(record.connection ?? connection, model: pinned)
    }
    return .inference(connection, model: connection.selectedModel)
  }
  /// Returns true when sending may proceed; otherwise asks once and leaves every draft untouched.
  func confirmDataSharing(_ destination: DataSharingDestination?, resume: Bool) -> Bool {
    guard let destination else { errorMessage = InferenceError.invalidEndpoint.localizedDescription; return false }
    if dataSharing.permits(destination) { return true }
    dataSharingRequest = .init(destination: destination, resume: resume, conversationID: selectedConversationID)
    return false
  }
  func answerDataSharing(_ request: DataSharingRequest, allowed: Bool) async {
    guard dataSharingRequest == request else { return }
    dataSharingRequest = nil
    guard allowed else { return }
    do { try setDataSharing(request.destination, allowed: true) }
    catch { errorMessage = error.localizedDescription; return }
    // Continue only the exact chat that asked; the permission itself is kept either way.
    guard selectedConversationID == request.conversationID else { return }
    if request.resume { await resumeDeviceRun() } else { await sendOnDevice() }
  }
  /// Web tools ask in the conversation the first time; a decline holds for that chat until relaunch.
  func confirmExaSharing(conversationID: String, toolCallID: String) async throws {
    if dataSharing.permits(.exa) { return }
    guard !exaSharingDeclined.contains(conversationID) else { throw QuickChatSearchError.permissionRequired }
    let token = UUID().uuidString
    let cancelWait: @MainActor @Sendable () -> Void = { [weak self] in self?.cancelDeviceApproval(toolCallID, token: token) }
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<LocalApprovalOutcome, Never>) in
        guard !Task.isCancelled else { continuation.resume(returning: .withdrawn); return }
        localApprovals[toolCallID] = .init(token: token, conversationID: conversationID, continuation: continuation)
        localPending.append(.init(id: toolCallID, conversationID: conversationID, runID: executionRecords[conversationID]?.runID,
          kind: .approval, title: "Allow web search with Exa?",
          detail: DataSharingDestination.exa.sharedData + " You can change this in Settings → Data sharing.",
          options: [.init(id: "allow", label: "Allow"), .init(id: "deny", label: "Don’t allow")]))
      }
    } onCancel: { [cancelWait] in
      Task { @MainActor [cancelWait] in cancelWait() }
    }
    try Task.checkCancellation()
    switch outcome {
    case .allowed: try setDataSharing(.exa, allowed: true)
    // Only the user's answer is remembered. Stop or interruption asks again on Resume.
    case .declined: exaSharingDeclined.insert(conversationID); throw QuickChatSearchError.permissionRequired
    case .withdrawn: throw CancellationError()
    }
  }
}

struct DataSharingConsentSheet: View {
  @Bindable var model: CompanionModel
  let request: DataSharingRequest
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text("Quick Chat sends content to \(request.destination.recipientName) to generate replies.")
            .font(.headline)
          VStack(alignment: .leading, spacing: 6) {
            Text("What is sent").font(.subheadline.weight(.semibold))
            Text(request.destination.sharedData).font(.callout)
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("Where it goes").font(.subheadline.weight(.semibold))
            Text(request.destination.origin).font(.callout.monospaced()).textSelection(.enabled)
            Text("Its handling is governed by that provider’s terms and privacy policy and your account with it. Woven Matter does not receive this content.")
              .font(.callout).foregroundStyle(.secondary)
          }
          Text(request.resume
            ? "Nothing more is sent until you allow this. If you don’t, the interrupted run stays saved and you can resume it later. You can review or withdraw permission in Settings → Data sharing."
            : "Nothing has been sent. Your message stays in the composer if you don’t allow this. You can review or withdraw permission in Settings → Data sharing.")
            .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("data-sharing-outcome")
          Button(request.resume ? "Allow and Resume" : "Allow and Send") { Task { await model.answerDataSharing(request, allowed: true) } }
            .buttonStyle(DashboardPrimaryButtonStyle()).frame(maxWidth: .infinity)
            .accessibilityIdentifier("data-sharing-allow")
          Button("Don’t Allow") { Task { await model.answerDataSharing(request, allowed: false) } }
            .buttonStyle(DashboardQuietButtonStyle()).frame(maxWidth: .infinity)
            .accessibilityIdentifier("data-sharing-deny")
        }.padding(20)
      }.navigationTitle("Share with \(request.destination.recipientName)?").navigationBarTitleDisplayMode(.inline)
    }.interactiveDismissDisabled()
  }
}

struct DataSharingSettingsPane: View {
  @Bindable var model: CompanionModel
  @State private var problem: String?
  var body: some View {
    Form {
      Section {
        Text("Quick Chat asks before sending your content to a model provider or to Exa. Each permission covers one provider endpoint; changing the endpoint asks again.")
          .font(.callout).foregroundStyle(.secondary)
      }
      Section("Allowed") {
        if model.dataSharing.current.isEmpty {
          Text("Nothing is allowed yet.").foregroundStyle(.secondary)
        }
        ForEach(model.dataSharing.current, id: \.destination.id) { grant in
          VStack(alignment: .leading, spacing: 4) {
            Text(grant.destination.recipientName)
            Text(grant.destination.origin).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(grant.destination.sharedData).font(.caption).foregroundStyle(.secondary)
            Button("Stop sharing", role: .destructive) {
              do { try model.setDataSharing(grant.destination, allowed: false); problem = nil }
              catch { problem = error.localizedDescription }
            }.font(.callout)
          }.accessibilityElement(children: .contain)
        }
      }
      Section {
        Text("Stopping sharing takes effect at the next request. Quick Chat asks again before it next sends to that endpoint.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let problem { Text(problem).foregroundStyle(DashboardPalette.danger) }
    }.mobileNavigationPage("Data sharing")
  }
}
