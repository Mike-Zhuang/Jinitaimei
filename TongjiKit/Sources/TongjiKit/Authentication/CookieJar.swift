import Foundation
@preconcurrency import WebKit

/// 结构化 Cookie 存储。
///
/// 替代旧版只存"name=value; name2=value2"拼接字符串的方式，原因：
/// - 旧版不知道 cookie 的 `expiresDate / domain / path / isSecure / isHTTPOnly`，
///   过期 cookie 也会一直发送。
/// - 服务器通过 `Set-Cookie` 滚动刷新 sessionId 时，旧版没法把响应里的新 cookie
///   回写到本地，导致本地 cookie 永远停留在首次登录那一刻的版本。
///
/// 持久化到 Keychain `tongji_cookies_jar`（JSON 编码）。旧 key `tongji_cookies`
/// 保留用作首次启动时的一次性迁移。
public struct StoredCookie: Codable, Hashable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresDate: Date?
    public let isSecure: Bool
    public let isHTTPOnly: Bool

    public init(name: String, value: String, domain: String, path: String,
                expiresDate: Date?, isSecure: Bool, isHTTPOnly: Bool) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresDate = expiresDate
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }
}

public final class CookieJar: @unchecked Sendable {

    public static let shared = CookieJar()

    private let store: CredentialStore
    private let lock = NSLock()
    private var cookies: [StoredCookie] = []

    public init(store: CredentialStore = .shared) {
        self.store = store
        load()
    }

    // MARK: - 查询

    /// 拼接当前 URL 适用的 Cookie 头（按 domain / path / expires 过滤、按 path 长度优先去重）。
    public func loadHeader(for url: URL) -> String {
        let snapshot: [StoredCookie] = {
            lock.lock(); defer { lock.unlock() }
            return cookies
        }()

        let now = Date()
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path

        let matched = snapshot.filter { c in
            if let exp = c.expiresDate, exp < now { return false }
            let bareDomain: String = {
                let d = c.domain.lowercased()
                return d.hasPrefix(".") ? String(d.dropFirst()) : d
            }()
            let hostMatches = host == bareDomain || host.hasSuffix("." + bareDomain)
            if !hostMatches { return false }
            return path.hasPrefix(c.path)
        }

        // 同名 cookie 取 path 最具体（最长）的那一条
        var byName: [String: StoredCookie] = [:]
        for c in matched.sorted(by: { $0.path.count < $1.path.count }) {
            byName[c.name] = c
        }
        return byName.values.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 用于 UI 层判断"是否还有任何可用的同济 cookie"。
    public func hasAnyTongjiCookie() -> Bool {
        let snapshot: [StoredCookie] = {
            lock.lock(); defer { lock.unlock() }
            return cookies
        }()
        let now = Date()
        return snapshot.contains { c in
            if let exp = c.expiresDate, exp < now { return false }
            return c.domain.lowercased().contains("tongji.edu.cn")
        }
    }

    // MARK: - 写入与合并

    /// 从响应头里的 `Set-Cookie` 合并新 cookie。
    public func mergeSetCookieFields(_ fields: [String: String], for url: URL) {
        let httpCookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        mergeNative(httpCookies)
    }

    /// 从 `WKHTTPCookieStore` / URLSession `HTTPCookie` 批量合并。
    public func mergeNative(_ httpCookies: [HTTPCookie]) {
        guard !httpCookies.isEmpty else { return }
        let converted = httpCookies.map { c in
            StoredCookie(
                name: c.name, value: c.value, domain: c.domain, path: c.path,
                expiresDate: c.expiresDate, isSecure: c.isSecure, isHTTPOnly: c.isHTTPOnly
            )
        }
        lock.lock()
        for c in converted {
            cookies.removeAll { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }
            cookies.append(c)
        }
        lock.unlock()
        persist()
    }

    /// 把旧版 raw 字符串 "name=value; name2=value2" 作为指定 host 主域 cookie 导入。
    /// 用于首次启动从 legacy `tongji_cookies` 迁移；以及 webview JS `document.cookie` 兜底导入。
    public func mergeRawCookieHeader(_ header: String, forHost host: String) {
        let parsed: [StoredCookie] = header.split(separator: ";").compactMap { sub in
            let trimmed = sub.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { return nil }
            let name = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            guard !name.isEmpty else { return nil }
            return StoredCookie(
                name: name, value: value, domain: host, path: "/",
                expiresDate: nil, isSecure: true, isHTTPOnly: false
            )
        }
        guard !parsed.isEmpty else { return }
        lock.lock()
        for c in parsed {
            cookies.removeAll { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }
            cookies.append(c)
        }
        lock.unlock()
        persist()
    }

    public func clear() {
        lock.lock(); cookies.removeAll(); lock.unlock()
        persist()
    }

    // MARK: - 持久化

    private func load() {
        if let raw = store.get(CredentialStore.Keys.tongjiCookiesJar),
           let data = raw.data(using: .utf8),
           let decoded = try? makeDecoder().decode([StoredCookie].self, from: data) {
            lock.lock(); cookies = decoded; lock.unlock()
            return
        }
        // legacy 一次性迁移
        if let legacy = store.get(CredentialStore.Keys.tongjiCookies), !legacy.isEmpty {
            mergeRawCookieHeader(legacy, forHost: "1.tongji.edu.cn")
        }
    }

    private func persist() {
        let snapshot: [StoredCookie] = {
            lock.lock(); defer { lock.unlock() }
            return cookies
        }()
        guard let data = try? makeEncoder().encode(snapshot),
              let str = String(data: data, encoding: .utf8) else { return }
        store.set(str, for: CredentialStore.Keys.tongjiCookiesJar)
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
