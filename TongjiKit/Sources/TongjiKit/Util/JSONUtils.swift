import Foundation

/// 与 wish_drom 中 `NormalizeJsonPayload` / `TryExtractTopLevelField` /
/// `TryExtractNestedField` 等价的 JSON 工具方法。
public enum JSONUtils {

    /// WebView `evaluateJavaScript` 返回值可能是被 `"..."` 包裹的字符串、
    /// `null`/`undefined`、或纯文本，统一归一化为 `String?`。
    public static func normalizeJavaScriptValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        let str: String
        if let s = raw as? String {
            str = s
        } else if let n = raw as? NSNumber {
            str = n.stringValue
        } else {
            str = "\(raw)"
        }

        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" || trimmed == "undefined" {
            return nil
        }

        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            if let data = trimmed.data(using: .utf8),
               let unwrapped = try? JSONDecoder().decode(String.self, from: data) {
                return unwrapped
            }
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// 对应 wish_drom `NormalizeJsonPayload`：剥离多余的 `"..."` 包裹与转义。
    public static func normalizeJsonPayload(_ raw: String) -> String {
        var current = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        for _ in 0..<3 {
            var changed = false

            if current.count >= 2, current.hasPrefix("\""), current.hasSuffix("\"") {
                if let data = current.data(using: .utf8),
                   let unwrapped = try? JSONDecoder().decode(String.self, from: data) {
                    current = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                } else {
                    current = String(current.dropFirst().dropLast())
                    changed = true
                }
            }
            if current.contains("\\\"") {
                current = current.replacingOccurrences(of: "\\\"", with: "\"")
                changed = true
            }
            if current.contains("\\/") {
                current = current.replacingOccurrences(of: "\\/", with: "/")
                changed = true
            }
            if !changed { break }
        }
        return current
    }

    /// 从顶层提取字符串字段。
    public static func extractTopLevelField(_ json: String, field: String) -> String? {
        let cleaned = normalizeJsonPayload(json)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any], let value = dict[field] else { return nil }
            return stringify(value)
        } catch {
            return nil
        }
    }

    /// 嵌套字段提取，如 `data.schoolCalendar.id`。
    public static func extractNestedField(_ json: String, path: [String]) -> String? {
        let cleaned = normalizeJsonPayload(json)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var current: Any? = root
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
            if current == nil { return nil }
        }
        return current.flatMap(stringify)
    }

    public static func stringify(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case is NSNull: return nil
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "\(value)"
        }
    }
}
