import SwiftUI
import WovenMatterClient

struct OpenCodeInteractions: View {
    @Bindable var model: OpenCodeModel
    let conversationID: String
    var body: some View {
        if let snapshot = model.snapshots[conversationID], !snapshot.permissions.isEmpty || !snapshot.forms.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.permissions, id: \.self) { permission in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Permission: " + permission["action"].text).fontWeight(.semibold)
                            Text(permission["resources"].array.map(\.text).joined(separator: "\n")).textSelection(.enabled)
                            if let explanation = permission["message"].string { Text(explanation).foregroundStyle(.secondary) }
                            HStack {
                                permissionButton("Allow Once", reply: "once", permission: permission)
                                if !permission["save"].array.isEmpty { permissionButton("Always Allow", reply: "always", permission: permission) }
                                permissionButton("Reject", reply: "reject", permission: permission)
                            }
                        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(snapshot.forms, id: \.self) { form in
                        OpenCodeFormView(form: form) { answer in
                            model.perform {
                                _ = try await model.sessionCall(conversationID, "/form/" + OpenCodeHTTPClient.segment(form["id"].text) + (answer == nil ? "/cancel" : "/reply"),
                                    method: "POST", body: answer.map { ["answer": $0] })
                            }
                        }.id(form["id"].text)
                    }
                }
            }.frame(maxHeight: 240)
        }
    }
    private func permissionButton(_ title: String, reply: String, permission: OpenCodeValue) -> some View {
        Button(title) { model.perform {
            _ = try await model.sessionCall(conversationID, "/permission/" + OpenCodeHTTPClient.segment(permission["id"].text) + "/reply", method: "POST", body: ["reply": .string(reply)])
        } }.buttonStyle(.bordered)
    }
}

private enum OpenCodeStringAnswerChoice: Hashable {
    case none, option(String), custom
}

struct OpenCodeFormView: View {
    let form: OpenCodeValue
    let onReply: (OpenCodeValue?) -> Void
    @State private var answers: [String: OpenCodeValue] = [:]
    @State private var invalid: String?
    @State private var customStringKeys: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(form["title"].text).fontWeight(.semibold)
            ForEach(OpenCodeFormAnswers.activeFields(form["fields"].array, answers: answers), id: \.self) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field["title"].string ?? field["key"].text)
                    if let description = field["description"].string { Text(description).font(.caption).foregroundStyle(.secondary) }
                    fieldControl(field)
                }
            }
            HStack {
                Button("Submit") { submit() }.buttonStyle(.borderedProminent)
                Button("Cancel") { onReply(nil) }.buttonStyle(.bordered)
            }
            if let invalid { Text(invalid).foregroundStyle(.red).font(.caption) }
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { for field in form["fields"].array where !field["default"].isNull { answers[field["key"].text] = field["default"] } }
    }
    @ViewBuilder private func fieldControl(_ field: OpenCodeValue) -> some View {
        let key = field["key"].text
        switch field["type"].text {
        case "external":
            if let url = URL(string: field["url"].text), ["https", "http"].contains(url.scheme) {
                Link("Open " + (field["title"].string ?? "verification"), destination: url)
            }
            Toggle("I’ve completed this step", isOn: Binding(
                get: { answers[key]?.bool ?? false }, set: { answers[key] = .bool($0) }
            ))
            .toggleStyle(DashboardSwitchToggleStyle())
        case "boolean":
            Toggle("Yes", isOn: Binding(get: { answers[key]?.bool ?? false }, set: { answers[key] = .bool($0) }))
                .toggleStyle(DashboardSwitchToggleStyle())
        case "multiselect":
            ForEach(field["options"].array, id: \.self) { option in
                Toggle(option["label"].text, isOn: Binding(get: { answers[key]?.array.contains(option["value"]) ?? false }, set: { selected in
                    var values = answers[key]?.array ?? []; values.removeAll { $0 == option["value"] }
                    if selected { values.append(option["value"]) }; answers[key] = .array(values)
                }))
                .toggleStyle(DashboardSwitchToggleStyle())
            }
            if field["custom"].bool { customInput(field) }
        case "string" where !field["options"].array.isEmpty:
            Picker("Answer", selection: Binding<OpenCodeStringAnswerChoice>(get: {
                let value = answers[key]?.text ?? ""
                if customStringKeys.contains(key) { return .custom }
                if field["options"].array.contains(where: { $0["value"].text == value }) { return .option(value) }
                return field["custom"].bool && !value.isEmpty ? .custom : .none
            }, set: { choice in
                customStringKeys.remove(key)
                switch choice {
                case .none: answers[key] = .null
                case .option(let value): answers[key] = .string(value)
                case .custom: customStringKeys.insert(key); answers[key] = .string("")
                }
            })) {
                Text("Choose…").tag(OpenCodeStringAnswerChoice.none)
                ForEach(field["options"].array, id: \.self) {
                    Text($0["label"].text).tag(OpenCodeStringAnswerChoice.option($0["value"].text))
                }
                if field["custom"].bool { Text("Custom answer…").tag(OpenCodeStringAnswerChoice.custom) }
            }.labelsHidden()
            if field["custom"].bool && (customStringKeys.contains(key) || (answers[key]?.string.map { value in
                !value.isEmpty && !field["options"].array.contains { $0["value"].text == value }
            } ?? false)) {
                TextField("Your answer", text: Binding(get: { answers[key]?.text ?? "" }, set: { customStringKeys.insert(key); answers[key] = .string($0) }))
                    .textFieldStyle(.roundedBorder)
            }
        default:
            TextField(field["placeholder"].string ?? "Answer", text: Binding(get: {
                if let number = answers[key]?.number { return String(number) }
                return answers[key]?.text ?? ""
            }, set: { answers[key] = .string($0) })).textFieldStyle(.roundedBorder)
        }
    }
    private func customInput(_ field: OpenCodeValue) -> some View {
        TextField("Additional choices, separated by commas", text: Binding(get: {
            (answers[field["key"].text]?.array ?? []).map(\.text).filter { value in !field["options"].array.contains { $0["value"].text == value } }.joined(separator: ", ")
        }, set: { text in
            let listed = (answers[field["key"].text]?.array ?? []).filter { value in field["options"].array.contains { $0["value"] == value } }
            answers[field["key"].text] = .array(listed + text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        })).textFieldStyle(.roundedBorder)
    }
    private func submit() {
        do {
            let result = try OpenCodeFormAnswers.reply(fields: form["fields"].array, answers: answers)
            invalid = nil
            onReply(result)
        } catch { invalid = error.localizedDescription }
    }
}
