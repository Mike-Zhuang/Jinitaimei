import CommonCrypto
import Foundation

/// 智能控水接口的 `info` 参数加密。
///
/// Android 下游项目 `Tongji/app/.../WaterCipher.kt` 已验证协议为
/// `AES/ECB/PKCS5Padding`。CommonCrypto 中 PKCS7 与 Java PKCS5 在 AES
/// 16 字节 block 下等价，因此这里使用 `kCCOptionECBMode | kCCOptionPKCS7Padding`。
public enum WaterControlCipher {
    public static let defaultAesKey = "3n4DdO47LWH2Co/WfpbdyA=="
    public static let defaultPassword = "kv7XjPzrDNJY0pdZ#"

    public static func encryptInfo(_ object: [String: Any], keyBase64: String) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let key = Data(base64Encoded: keyBase64) else {
            throw AuthError.loginFlowFailed("水控 AES Key 无法解码")
        }
        let encrypted = try aesECBPKCS7Encrypt(data: json, key: key)
        return encrypted.base64EncodedString()
    }

    public static func findAesKey(in jsTexts: [String]) -> String? {
        let pattern = #""([A-Za-z0-9+/]{22}==)"|'([A-Za-z0-9+/]{22}==)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for text in jsTexts {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard let candidate = firstCapture(in: text, match: match) else { continue }
                guard let raw = Data(base64Encoded: candidate), [16, 24, 32].contains(raw.count) else {
                    continue
                }
                let around = surroundingText(text, match: match, before: 500, after: 1_000)
                if around.contains("AES.encrypt") || around.contains("AES.decrypt") {
                    return candidate
                }
            }
        }
        return nil
    }

    public static func findPassword(in jsTexts: [String]) -> String? {
        let pattern = #"userpassword\s*:\s*["']([^"']{6,100})["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for text in jsTexts {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[range])
                if !value.lowercased().hasPrefix("string") {
                    return value
                }
            }
        }
        return nil
    }

    private static func aesECBPKCS7Encrypt(data: Data, key: Data) throws -> Data {
        let outputLength = data.count + kCCBlockSizeAES128
        var output = Data(count: outputLength)
        var bytesWritten = 0

        let status = output.withUnsafeMutableBytes { outputPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyPtr.baseAddress,
                        key.count,
                        nil,
                        dataPtr.baseAddress,
                        data.count,
                        outputPtr.baseAddress,
                        outputLength,
                        &bytesWritten
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw AuthError.loginFlowFailed("水控 AES 加密失败 (\(status))")
        }
        output.removeSubrange(bytesWritten..<output.count)
        return output
    }

    private static func firstCapture(in text: String, match: NSTextCheckingResult) -> String? {
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: text) else { continue }
            return String(text[swiftRange])
        }
        return nil
    }

    private static func surroundingText(
        _ text: String,
        match: NSTextCheckingResult,
        before: Int,
        after: Int
    ) -> String {
        guard let range = Range(match.range, in: text) else { return "" }
        let lower = text.index(range.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper])
    }
}
