import Foundation
import WovenProtocol

/// Forms in the one prompt shape: a flat JSON Schema object (as ACP's and
/// MCP's elicitation send) read into fields, and answers checked against them.
enum PromptForms {
  /// The fields of a flat object schema, in the order its properties are
  /// listed by key; nil for a schema the chat cannot show.
  static func fields(_ schema: JSONValue) -> [PromptField]? {
    guard schema["type"]?.string == "object", case .object(let properties)? = schema["properties"] else { return nil }
    let required = Set((schema["required"]?.array ?? []).compactMap(\.string))
    var fields: [PromptField] = []
    for key in properties.keys.sorted() {
      guard let property = properties[key], let field = field(key, property, required: required.contains(key)) else { return nil }
      fields.append(field)
    }
    return fields
  }

  private static func field(_ key: String, _ property: JSONValue, required: Bool) -> PromptField? {
    var field = PromptField(id: key, title: property["title"]?.string ?? key, detail: property["description"]?.string,
                            required: required, initial: property["default"])
    switch property["type"]?.string {
    case "string":
      let options = choices(property)
      if options.isEmpty {
        field.kind = .text
        field.minimum = property["minLength"]?.double
        field.maximum = property["maxLength"]?.double
      } else {
        field.kind = .choice
        field.options = options
      }
    case "array":
      guard let items = property["items"] else { return nil }
      field.kind = .choices
      field.options = choices(items)
      guard !field.options.isEmpty else { return nil }
      field.minimum = property["minItems"]?.double
      field.maximum = property["maxItems"]?.double
    case "number", "integer":
      field.kind = property["type"]?.string == "integer" ? .integer : .number
      field.minimum = property["minimum"]?.double
      field.maximum = property["maximum"]?.double
    case "boolean":
      field.kind = .boolean
    default:
      return nil
    }
    return field
  }

  /// `enum` (with `enumNames`), or `oneOf`/`anyOf` of `const` values.
  private static func choices(_ property: JSONValue) -> [PromptOption] {
    if let values = property["enum"]?.array {
      let names = property["enumNames"]?.array
      return values.enumerated().compactMap { index, value in
        value.string.map { PromptOption(id: $0, name: names?[safe: index]?.string ?? $0) }
      }
    }
    return (property["oneOf"]?.array ?? property["anyOf"]?.array ?? []).compactMap { option in
      option["const"]?.string.map { PromptOption(id: $0, name: option["title"]?.string ?? $0, detail: option["description"]?.string) }
    }
  }

  /// A form as a prompt. A form of one field with fixed choices is a question,
  /// asked in the form's message, the field's title and its description.
  static func prompt(id: String, message: String, fields: [PromptField]) -> Prompt {
    if fields.count == 1, fields[0].kind == .choice {
      let text = [message, name(fields[0]), fields[0].detail].compactMap { $0 }
        .filter { !$0.isEmpty }.joined(separator: "\n")
      return Prompt(id: id, kind: .question, text: text, options: fields[0].options, fields: fields)
    }
    return Prompt(id: id, kind: .form, text: message, fields: fields)
  }

  /// Throws when the values leave out a required field or do not fit one.
  static func check(_ values: [String: JSONValue], against fields: [PromptField]) throws {
    for key in values.keys where !fields.contains(where: { $0.id == key }) {
      throw RuntimeError.failed("The form has no field \(key).")
    }
    for field in fields {
      guard let value = values[field.id], value != .null else {
        if field.required { throw RuntimeError.failed("\(name(field) ?? "This question") needs an answer.") }
        continue
      }
      guard fits(value, field) else {
        throw RuntimeError.failed(name(field).map { "That is not an answer \($0) takes." } ?? "That is not one of the answers offered.")
      }
    }
  }

  /// A field's title, unless it is only the field's key.
  private static func name(_ field: PromptField) -> String? {
    field.title.isEmpty || field.title == field.id ? nil : field.title
  }

  private static func fits(_ value: JSONValue, _ field: PromptField) -> Bool {
    func within(_ number: Double) -> Bool {
      (field.minimum.map { number >= $0 } ?? true) && (field.maximum.map { number <= $0 } ?? true)
    }
    func offered(_ answer: String?) -> Bool {
      guard let answer else { return false }
      return field.options.contains { $0.id == answer } || (field.ownAnswer && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    switch (field.kind, value) {
    case (.text, .string(let text)): return within(Double(text.count))
    case (.choice, .string(let id)): return offered(id)
    case (.choices, .array(let ids)):
      return within(Double(ids.count)) && ids.allSatisfy { offered($0.string) }
    case (.number, _): return value.double.map(within) ?? false
    case (.integer, _): return value.double.map { $0.rounded() == $0 && within($0) } ?? false
    case (.boolean, .bool): return true
    default: return false
    }
  }
}

extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
