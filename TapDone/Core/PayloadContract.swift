import Foundation

/// Deliberately bounded JSON Schema subset, shared by import, CLI and runtime.
/// Unsupported keywords are rejected, never silently treated as validation.
public struct PayloadContract: Codable, Equatable {
    public let schema: JSONValue
    private static let kinds = Set(["object", "array", "string", "number", "integer", "boolean", "null"])

    public init(from decoder: Decoder) throws {
        schema = try JSONValue(from: decoder)
        try Self.checkDefinition(schema, path: "$", depth: 0)
        guard try JSONEncoder().encode(schema).count <= 65536 else {
            throw TapDoneError("INVALID_CONTRACT", "输入输出约束不能超过 64 KB。")
        }
    }
    public func encode(to encoder: Encoder) throws { try schema.encode(to: encoder) }

    public func validate(_ value: JSONValue, path: String = "$") throws {
        try Self.checkValue(value, schema: schema, path: path)
    }

    private static func fail(_ path: String, _ message: String, definition: Bool = false) -> TapDoneError {
        TapDoneError(definition ? "INVALID_CONTRACT" : "CONTRACT_MISMATCH", "\(path)：\(message)")
    }
    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }; return object
    }
    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }; return string
    }
    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value else { return nil }; return number
    }
    private static func required(_ object: [String: JSONValue]) -> [String] {
        guard case .array(let values)? = object["required"] else { return [] }
        return values.compactMap { string($0) }
    }
    private static func allowsAdditional(_ object: [String: JSONValue]) -> Bool {
        object["additionalProperties"] == .bool(true)
    }

    private static func checkDefinition(_ schema: JSONValue, path: String, depth: Int) throws {
        guard depth <= 12, let shape = object(schema), let type = string(shape["type"]), kinds.contains(type) else {
            throw fail(path, "约束必须包含支持的 type，嵌套不能超过 12 层。", definition: true)
        }
        var allowed: Set<String> = ["type"]
        switch type {
        case "object": allowed.formUnion(["properties", "required", "additionalProperties"])
        case "array": allowed.insert("items")
        case "string": allowed.formUnion(["minLength", "maxLength"])
        case "number", "integer": allowed.formUnion(["minimum", "maximum"])
        default: break
        }
        guard Set(shape.keys).isSubset(of: allowed) else {
            throw fail(path, "不支持的约束字段：\(Set(shape.keys).subtracting(allowed).sorted().joined(separator: ", "))", definition: true)
        }
        if type == "object" {
            let properties = object(shape["properties"]) ?? [:]
            guard (shape["properties"] == nil || object(shape["properties"]) != nil), properties.count <= 128 else {
                throw fail(path, "properties 必须是最多 128 个字段的对象。", definition: true)
            }
            if let raw = shape["required"] {
                guard case .array(let values) = raw, values.count == required(shape).count,
                      Set(required(shape)).count == values.count,
                      Set(required(shape)).isSubset(of: Set(properties.keys)) else {
                    throw fail(path, "required 必须是不重复的属性名称数组，且属性必须在 properties 中声明。", definition: true)
                }
            }
            if let additional = shape["additionalProperties"], additional != .bool(true), additional != .bool(false) {
                throw fail(path, "additionalProperties 只接受布尔值。", definition: true)
            }
            for (key, child) in properties {
                guard !key.isEmpty, key.utf8.count <= 256 else { throw fail(path, "属性名称为空或过长。", definition: true) }
                try checkDefinition(child, path: path + "." + key, depth: depth + 1)
            }
        } else if type == "array" {
            guard let items = shape["items"] else { throw fail(path, "数组约束必须指定 items。", definition: true) }
            try checkDefinition(items, path: path + "[]", depth: depth + 1)
        }
        for key in ["minLength", "maxLength", "minimum", "maximum"] where shape[key] != nil {
            guard let value = number(shape[key]), value.isFinite else { throw fail(path, "\(key) 必须是有限数值。", definition: true) }
            if key.hasSuffix("Length"), value < 0 || value.rounded() != value || value > 1048576 {
                throw fail(path, "长度必须是 0–1048576 的整数。", definition: true)
            }
        }
        for (lower, upper) in [("minLength", "maxLength"), ("minimum", "maximum")] {
            if let a = number(shape[lower]), let b = number(shape[upper]), a > b {
                throw fail(path, "下限不能大于上限。", definition: true)
            }
        }
    }

    private static func checkValue(_ value: JSONValue, schema: JSONValue, path: String) throws {
        guard let shape = object(schema), let type = string(shape["type"]) else { throw fail(path, "约束无效。") }
        switch (type, value) {
        case ("object", .object(let data)):
            let properties = object(shape["properties"]) ?? [:]
            let missing = Set(required(shape)).subtracting(data.keys)
            guard missing.isEmpty else { throw fail(path, "缺少必填字段：\(missing.sorted().joined(separator: ", "))") }
            let unknown = Set(data.keys).subtracting(properties.keys)
            guard allowsAdditional(shape) || unknown.isEmpty else { throw fail(path, "存在未声明字段：\(unknown.sorted().joined(separator: ", "))") }
            for (key, child) in properties {
                if let data = data[key] { try checkValue(data, schema: child, path: path + "." + key) }
            }
        case ("array", .array(let data)):
            guard let items = shape["items"] else { throw fail(path, "数组约束缺少 items。") }
            for (index, item) in data.enumerated() { try checkValue(item, schema: items, path: path + "[\(index)]") }
        case ("string", .string(let data)):
            // JSON Schema lengths count Unicode scalar values, not Swift grapheme clusters.
            let count = Double(data.unicodeScalars.count)
            if let min = number(shape["minLength"]), count < min { throw fail(path, "字符串短于 minLength。") }
            if let max = number(shape["maxLength"]), count > max { throw fail(path, "字符串长于 maxLength。") }
        case ("number", .number(let data)), ("integer", .number(let data)):
            guard data.isFinite, type != "integer" || data.rounded() == data else { throw fail(path, "数值不是所需的有限数或整数。") }
            if let min = number(shape["minimum"]), data < min { throw fail(path, "数值小于 minimum。") }
            if let max = number(shape["maximum"]), data > max { throw fail(path, "数值大于 maximum。") }
        case ("boolean", .bool), ("null", .null): break
        default: throw fail(path, "数据类型必须为 \(type)。")
        }
    }
}
