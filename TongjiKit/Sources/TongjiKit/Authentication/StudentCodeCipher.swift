import Foundation
import CommonCrypto

/// 复现同济一系统前端 webpack 模块 `hpw7` 的加密逻辑：
/// `encodeURIComponent(uid) → AES-CBC-PKCS7 → Base64 → encodeURIComponent`。
///
/// 移植自 wish_drom `TongjiScheduleProvider.EncryptStudentCode`。
public enum StudentCodeCipher {

    /// 用从 `sessiondata` 提取的 `aesKey` / `aesIv` 加密 `uid`，生成 API 参数 `studentCode`。
    public static func encryptStudentCode(uid: String, aesKey: String, aesIv: String) throws -> String {
        try encryptOneSystemText(uid, aesKey: aesKey, aesIv: aesIv)
    }

    /// 复用一系统前端通用加密链路，加密任意文本参数。
    public static func encryptOneSystemText(_ text: String, aesKey: String, aesIv: String) throws -> String {
        let processedKey = paramHandler(aesKey)
        let processedIv = paramHandler(aesIv)

        guard let keyBytes = processedKey.data(using: .utf8),
              let ivBytes = processedIv.data(using: .utf8) else {
            throw CipherError.invalidKey
        }

        // encodeURIComponent(text)：百分号编码所有非 ALPHA / DIGIT / -._~ 字符
        let encodedText = encodeURIComponent(text)
        guard let plainBytes = encodedText.data(using: .utf8) else {
            throw CipherError.invalidPlaintext
        }

        let cipher = try aesCbcEncrypt(data: plainBytes, key: keyBytes, iv: ivBytes)
        let base64 = cipher.base64EncodedString()
        return encodeURIComponent(base64)
    }

    /// JS `encodeURIComponent` 等价实现，供需要二次编码的接口复用。
    public static func encodeURIComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .uriComponentAllowed) ?? text
    }

    /// 前端 `paramHandler`：把字符串相邻字符两两交换。`"abcd"` → `"badc"`，奇数末尾保留。
    static func paramHandler(_ input: String) -> String {
        let chars = Array(input)
        var result = chars
        var i = 0
        while i + 1 < chars.count {
            result[i] = chars[i + 1]
            result[i + 1] = chars[i]
            i += 2
        }
        return String(result)
    }

    private static func aesCbcEncrypt(data: Data, key: Data, iv: Data) throws -> Data {
        let bufferSize = data.count + kCCBlockSizeAES128
        var output = Data(count: bufferSize)
        var bytesWritten = 0

        let status = output.withUnsafeMutableBytes { outputPtr -> CCCryptorStatus in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outputPtr.baseAddress, bufferSize,
                            &bytesWritten
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw CipherError.encryptionFailed(Int(status))
        }
        return output.prefix(bytesWritten)
    }

    public enum CipherError: Error {
        case invalidKey
        case invalidPlaintext
        case encryptionFailed(Int)
    }
}

extension CharacterSet {
    /// JS `encodeURIComponent` 允许的字符集：ALPHA / DIGIT / `-._~`
    fileprivate static let uriComponentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
