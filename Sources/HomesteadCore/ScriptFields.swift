// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// One input a script asks for when it is run — a name, a passcode, which
/// lock — from the `fields` Home Assistant's `get_services` reports for it.
public struct ScriptField: Equatable, Sendable {
    /// How the field is entered, from its `selector`.
    public enum Control: Equatable, Sendable {
        /// `secure` for `selector.text.type: password`.
        case text(secure: Bool)
        case select([Option])
        case number(min: Double?, max: Double?)
        case boolean
    }

    /// A select choice: what is sent, and what is shown.
    public struct Option: Equatable, Sendable {
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    /// The variable the script reads.
    public let key: String
    /// The field's `name`, or its key when it has none.
    public let name: String
    public let description: String?
    public let required: Bool
    public let defaultValue: JSONValue?
    public let control: Control

    public init(key: String, name: String, description: String? = nil, required: Bool = false,
                defaultValue: JSONValue? = nil, control: Control = .text(secure: false)) {
        self.key = key
        self.name = name
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
        self.control = control
    }

    /// Reads one entry of a script's `fields`. Selectors with no control of
    /// their own here (entity, date, a multi-select…) become plain text.
    init(key: String, spec: JSONValue) {
        let selector = spec["selector"]
        let control: Control
        if let text = selector?["text"] {
            control = .text(secure: text["type"]?.string == "password")
        } else if let select = selector?["select"], select["multiple"]?.bool != true,
                  let options = select["options"]?.array, !options.isEmpty {
            control = .select(options.compactMap { option in
                if let value = option.string { return Option(value: value, label: value) }
                guard let value = option["value"].flatMap(Self.text(of:)) else { return nil }
                return Option(value: value, label: option["label"]?.string ?? value)
            })
        } else if let number = selector?["number"] {
            control = .number(min: number["min"]?.double, max: number["max"]?.double)
        } else if selector?["boolean"] != nil {
            control = .boolean
        } else {
            control = .text(secure: false)
        }
        let name = spec["name"]?.string ?? ""
        let description = spec["description"]?.string ?? ""
        self.init(key: key,
                  name: name.isEmpty ? key : name,
                  description: description.isEmpty ? nil : description,
                  required: spec["required"]?.bool ?? false,
                  defaultValue: spec["default"].flatMap { $0 == .null ? nil : $0 },
                  control: control)
    }

    /// Placeholder text for the field's box: a number's allowed range.
    public var placeholder: String? {
        guard case .number(let min, let max) = control else { return nil }
        switch (min, max) {
        case let (min?, max?): return "\(SensorText.trimmed(min))–\(SensorText.trimmed(max))"
        case let (min?, nil): return "\(SensorText.trimmed(min)) or more"
        case let (nil, max?): return "Up to \(SensorText.trimmed(max))"
        case (nil, nil): return nil
        }
    }

    /// A scalar as text: a default or an option value may be a number.
    static func text(of value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .number(let number): return SensorText.trimmed(number)
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }
}

public enum ScriptFields {
    /// Every script that asks for input, by object id (`add_guest` for
    /// `script.add_guest`), with its fields in the order the script
    /// declares them. Scripts without fields are left out.
    ///
    /// - Parameter servicesFrame: the whole `result` frame of a `get_services`
    ///   command, as text. Text rather than a `JSONValue` because the order of
    ///   a script's fields is the order of its keys, which a dictionary loses;
    ///   `JSONKeyOrder` reads it from the text.
    public static func parse(servicesFrame text: String) -> [String: [ScriptField]] {
        guard let frame = try? JSONValue.parse(Data(text.utf8)), let result = frame["result"] else { return [:] }
        return parse(services: result, order: JSONKeyOrder.scriptFieldOrder(inServicesFrame: text))
    }

    /// - Parameters:
    ///   - services: `get_services`' result: domain → service → description.
    ///   - order: each script's field keys in declared order. A field it does
    ///     not list goes after, alphabetically, as do all of a script it
    ///     does not cover.
    public static func parse(services: JSONValue, order: [String: [String]] = [:]) -> [String: [ScriptField]] {
        var scripts: [String: [ScriptField]] = [:]
        for (objectId, service) in services["script"]?.object ?? [:] {
            guard let specs = service["fields"]?.object, !specs.isEmpty else { continue }
            let declared = (order[objectId] ?? []).filter { specs[$0] != nil }
            let rest = specs.keys.filter { !declared.contains($0) }.sorted()
            scripts[objectId] = (declared + rest).compactMap { key in
                specs[key].map { ScriptField(key: key, spec: $0) }
            }
        }
        return scripts
    }
}

/// What has been entered in a field so far.
public enum ScriptFormValue: Equatable, Sendable {
    case text(String)
    case bool(Bool)
}

/// The script's Run form, minus the window: what each field starts as, and
/// the service data the entries make.
public enum ScriptForm {
    /// Each field's `default`, or empty. A select with no default starts on
    /// its blank choice rather than quietly on its first option.
    public static func initialValues(_ fields: [ScriptField]) -> [String: ScriptFormValue] {
        var values: [String: ScriptFormValue] = [:]
        for field in fields {
            switch field.control {
            case .boolean:
                values[field.key] = .bool(field.defaultValue?.bool ?? false)
            case .text, .select, .number:
                values[field.key] = .text(field.defaultValue.flatMap(ScriptField.text(of:)) ?? "")
            }
        }
        return values
    }

    /// The service data, or nil while the form cannot be run: a required
    /// field is empty, or a number does not parse or is out of range. Numbers
    /// go as numbers and switches as booleans; an empty optional field is
    /// left out, so the script's own default applies.
    public static func serviceData(fields: [ScriptField], values: [String: ScriptFormValue]) -> [String: JSONValue]? {
        var data: [String: JSONValue] = [:]
        for field in fields {
            if case .boolean = field.control {
                if case .bool(let on)? = values[field.key] { data[field.key] = .bool(on) }
                continue
            }
            guard case .text(let text)? = values[field.key],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if field.required { return nil }
                continue
            }
            switch field.control {
            case .number(let min, let max):
                guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite,
                      number >= (min ?? -.infinity), number <= (max ?? .infinity) else { return nil }
                data[field.key] = .number(number)
            case .text, .select, .boolean:
                // Sent exactly as typed: a passcode's spaces are its own.
                data[field.key] = .string(text)
            }
        }
        return data
    }
}

/// Reads object keys in the order they are written. `JSONValue`, like
/// Foundation's own decoders, keeps an object as a dictionary, so the order
/// is gone by the time it is parsed; this scans the text for it instead.
enum JSONKeyOrder {
    /// `result.script.<object_id>.fields`' keys for every script in a
    /// `get_services` frame. Empty if the text is not what it expects.
    static func scriptFieldOrder(inServicesFrame text: String) -> [String: [String]] {
        let scanner = Scanner(text)
        var order: [String: [String]] = [:]
        do {
            try scanner.members { key in
                guard key == "result" else { return }
                try scanner.members { domain in
                    guard domain == "script" else { return }
                    try scanner.members { script in
                        try scanner.members { attribute in
                            guard attribute == "fields" else { return }
                            var keys: [String] = []
                            try scanner.members { keys.append($0) }
                            order[script] = keys
                        }
                    }
                }
            }
        } catch {
            return [:]
        }
        return order
    }

    struct Malformed: Error {}

    /// A cursor over the UTF-8 text that walks objects key by key and skips
    /// every value nobody asks for.
    final class Scanner {
        private let bytes: [UInt8]
        private var index = 0

        init(_ text: String) { bytes = Array(text.utf8) }

        /// At an object: runs `visit` for each key with the cursor on its
        /// value. A value `visit` does not read is skipped. Anything other
        /// than an object is skipped whole.
        func members(_ visit: (String) throws -> Void) throws {
            skipWhitespace()
            guard peek == UInt8(ascii: "{") else { return try skipValue() }
            index += 1
            skipWhitespace()
            if peek == UInt8(ascii: "}") { index += 1; return }
            while true {
                skipWhitespace()
                let key = try string()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                let start = index
                try visit(key)
                if index == start { try skipValue() }
                skipWhitespace()
                if peek == UInt8(ascii: ",") { index += 1; continue }
                try expect("}")
                return
            }
        }

        private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        private func skipWhitespace() {
            while let byte = peek, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
        }

        private func expect(_ character: Unicode.Scalar) throws {
            guard peek == UInt8(ascii: character) else { throw Malformed() }
            index += 1
        }

        private func string() throws -> String {
            let start = index
            try skipString()
            let literal = bytes[start..<index]
            guard literal.contains(UInt8(ascii: "\\")) else {
                return String(decoding: literal.dropFirst().dropLast(), as: UTF8.self)
            }
            guard let decoded = try JSONSerialization.jsonObject(with: Data(literal), options: .fragmentsAllowed)
                as? String else { throw Malformed() }
            return decoded
        }

        private func skipString() throws {
            try expect("\"")
            while let byte = peek {
                index += 1
                if byte == UInt8(ascii: "\\") { index += 1 } else if byte == UInt8(ascii: "\"") { return }
            }
            throw Malformed()
        }

        private func skipValue() throws {
            skipWhitespace()
            guard let first = peek else { throw Malformed() }
            switch first {
            case UInt8(ascii: "\""):
                try skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while let byte = peek {
                    switch byte {
                    case UInt8(ascii: "\""):
                        try skipString()
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                    default:
                        break
                    }
                    index += 1
                    if depth == 0 { return }
                }
                throw Malformed()
            default:
                // A number, true, false or null: runs to the next delimiter.
                while let byte = peek, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                                         0x20, 0x0A, 0x0D, 0x09].contains(byte) { index += 1 }
            }
        }
    }
}
