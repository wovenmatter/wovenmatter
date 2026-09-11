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

struct OpenCodeFormView: View {
    let form: OpenCodeValue
    let onReply: (OpenCodeValue?) -> Void
    @State private var answers: [String: OpenCodeValue] = [:]
    @State private var invalid: String?
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
        case "boolean": Toggle("Yes", isOn: Binding(get: { answers[key]?.bool ?? false }, set: { answers[key] = .bool($0) }))
        case "multiselect":
            ForEach(field["options"].array, id: \.self) { option in
                Toggle(option["label"].text, isOn: Binding(get: { answers[key]?.array.contains(option["value"]) ?? false }, set: { selected in
                    var values = answers[key]?.array ?? []; values.removeAll { $0 == option["value"] }
                    if selected { values.append(option["value"]) }; answers[key] = .array(values)
                }))
            }
            if field["custom"].bool { customInput(field) }
        case "string" where !field["options"].array.isEmpty && !field["custom"].bool:
            Picker("Answer", selection: Binding(get: { answers[key]?.text ?? "" }, set: { answers[key] = .string($0) })) {
                Text("Choose…").tag("")
                ForEach(field["options"].array, id: \.self) { Text($0["label"].text).tag($0["value"].text) }
            }.labelsHidden()
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
        var result: [String: OpenCodeValue] = [:]
        for field in OpenCodeFormAnswers.activeFields(form["fields"].array, answers: answers) where field["type"].text != "external" {
            let key = field["key"].text
            var value = answers[key] ?? (field["type"].text == "boolean" ? .bool(false) : .null)
            if ["number", "integer"].contains(field["type"].text), value == .string("") { value = .null }
            if ["number", "integer"].contains(field["type"].text), !value.isNull {
                guard let parsed = value.number ?? Double(value.text), parsed.isFinite else { invalid = "Enter a number for \(key)."; return }
                guard field["type"].text != "integer" || parsed.rounded() == parsed else { invalid = "Enter a whole number for \(key)."; return }
                if let minimum = field["minimum"].number, parsed < minimum { invalid = "\(key) must be at least \(minimum)."; return }
                if let maximum = field["maximum"].number, parsed > maximum { invalid = "\(key) must be at most \(maximum)."; return }
                value = .number(parsed)
            }
            if field["required"].bool && (value.isNull || value == .string("") || value == .array([])) { invalid = "Complete \(field["title"].string ?? key)."; return }
            if !value.isNull { result[key] = value }
        }
        invalid = nil; onReply(.object(result))
    }
}
