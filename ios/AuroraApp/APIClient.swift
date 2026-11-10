// APIClient.swift — async/await 网络层：Bearer 令牌 + 手动 Cookie 刷新 + 401 自动重放
import Foundation

enum APIError: LocalizedError {
    case transport(String)
    case http(status: Int, message: String, code: String?)

    var errorDescription: String? {
        switch self {
        case .transport(let message): return message
        case .http(_, let message, _): return message
        }
    }

    var isUnauthorized: Bool {
        if case .http(let status, _, _) = self { return status == 401 }
        return false
    }

    var isConflict: Bool {
        if case .http(let status, _, _) = self { return status == 409 }
        return false
    }
}

final class APIClient {
    static let shared = APIClient()

    let baseURL: URL

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private(set) var accessToken: String?
    private(set) var refreshCookie: String?
    private var refreshTask: Task<Void, Error>?

    /// 会话彻底失效时通知上层回到登录页
    var onUnauthorized: (() -> Void)?

    private struct Credentials: Encodable {
        let email: String
        let password: String
    }

    init(baseURL: URL = AppConfig.apiBaseURL) {
        self.baseURL = baseURL

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 40
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        // 完全手动管理 Cookie，避免依赖系统 Cookie 存储的时序差异
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "X-Aurora-Client": "ios/\(AppConfig.versionLabel)",
        ]
        self.session = URLSession(configuration: cfg)
    }

    /* ── 令牌生命周期 ─────────────────────────────────────── */

    func adopt(access: String) {
        accessToken = access
        Keychain.set(access, for: .access)
    }

    func restoreFromKeychain() -> Bool {
        accessToken = Keychain.get(.access)
        refreshCookie = Keychain.get(.refresh)
        return accessToken != nil || refreshCookie != nil
    }

    func forget() {
        accessToken = nil
        refreshCookie = nil
        Keychain.clearAll()
    }

    /* ── 请求构造 ─────────────────────────────────────────── */

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.transport("服务器地址不合法")
        }
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw APIError.transport("服务器地址不合法")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token = accessToken, !path.hasPrefix("/api/auth/") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if path == "/api/auth/refresh", let cookie = refreshCookie {
            request.setValue("\(AppConfig.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    @discardableResult
    private func perform(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        json: Data? = nil,
        retryOn401: Bool = true
    ) async throws -> Data {
        var request = try makeRequest(method, path, query: query)
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            return try await send(request)
        } catch let error as APIError where error.isUnauthorized && retryOn401 && !path.hasPrefix("/api/auth/") {
            try await refreshSession()
            var replay = try makeRequest(method, path, query: query)
            if let json {
                replay.httpBody = json
                replay.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return try await send(replay)
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let outcome: (Data, URLResponse)
        do {
            outcome = try await session.data(for: request)
        } catch {
            throw APIError.transport("连不上服务端，检查地址与网络后重试")
        }

        let data = outcome.0
        guard let http = outcome.1 as? HTTPURLResponse else {
            throw APIError.transport("服务端响应异常")
        }

        captureRefreshCookie(from: http)

        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            let message = envelope?.error ?? "请求失败（\(http.statusCode)）"
            throw APIError.http(status: http.statusCode, message: message, code: envelope?.code)
        }
        return data
    }

    private func captureRefreshCookie(from response: HTTPURLResponse) {
        guard let setCookie = response.value(forHTTPHeaderField: "Set-Cookie"),
              setCookie.contains("\(AppConfig.cookieName)=")
        else { return }

        if let value = Self.cookieValue(in: setCookie) {
            refreshCookie = value
            Keychain.set(value, for: .refresh)
        } else {
            // 服务端下发清空 Cookie（登出 / 复用检测）
            refreshCookie = nil
            Keychain.remove(.refresh)
        }
    }

    /// 从可能被折叠成一条的 Set-Cookie 里取出 aurora_rt 的值
    static func cookieValue(in raw: String) -> String? {
        for segment in raw.components(separatedBy: ";") {
            let part = segment.trimmingCharacters(in: .whitespaces)
            guard part.hasPrefix("\(AppConfig.cookieName)=") else { continue }
            let value = String(part.dropFirst(AppConfig.cookieName.count + 1)).trimmed
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /* ── 刷新（并发合并为一次） ───────────────────────────── */

    func refreshSession() async throws {
        if let running = refreshTask {
            try await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performRefresh()
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            try await task.value
        } catch {
            forget()
            onUnauthorized?()
            throw error
        }
    }

    private func performRefresh() async throws {
        guard refreshCookie != nil else {
            throw APIError.http(status: 401, message: "登录已过期，请重新登录", code: "no_refresh")
        }
        let data = try await perform("POST", "/api/auth/refresh", json: Data("{}".utf8), retryOn401: false)
        let revived = try decoder.decode(Session.self, from: data)
        adopt(access: revived.access)
    }

    /* ── 业务接口 ─────────────────────────────────────────── */

    func login(email: String, password: String) async throws -> Session {
        let body = try encoder.encode(Credentials(email: email, password: password))
        let data = try await perform("POST", "/api/auth/login", json: body, retryOn401: false)
        let session = try decoder.decode(Session.self, from: data)
        adopt(access: session.access)
        return session
    }

    func register(email: String, password: String) async throws -> Session {
        let body = try encoder.encode(Credentials(email: email, password: password))
        let data = try await perform("POST", "/api/auth/register", json: body, retryOn401: false)
        let session = try decoder.decode(Session.self, from: data)
        adopt(access: session.access)
        return session
    }

    func logout() async {
        _ = try? await perform("POST", "/api/auth/logout", json: Data("{}".utf8), retryOn401: false)
        forget()
    }

    func me() async throws -> User {
        let data = try await perform("GET", "/api/me")
        return try decoder.decode(MeEnvelope.self, from: data).user
    }

    func stats() async throws -> Stats {
        let data = try await perform("GET", "/api/stats")
        return try decoder.decode(Stats.self, from: data)
    }

    func notes(query: String = "", status: NoteStatus? = nil) async throws -> [Note] {
        var items: [URLQueryItem] = []
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let status { items.append(URLQueryItem(name: "status", value: status.rawValue)) }
        let data = try await perform("GET", "/api/notes", query: items)
        return try decoder.decode(NotesEnvelope.self, from: data).notes
    }

    func createNote(_ note: NewNote) async throws -> Note {
        let data = try await perform("POST", "/api/notes", json: try encoder.encode(note))
        return try decoder.decode(NoteEnvelope.self, from: data).note
    }

    func patchNote(id: String, patch: NotePatch) async throws -> Note {
        let data = try await perform("PATCH", "/api/notes/\(id)", json: try encoder.encode(patch))
        return try decoder.decode(NoteEnvelope.self, from: data).note
    }

    func deleteNote(id: String) async throws {
        _ = try await perform("DELETE", "/api/notes/\(id)")
    }
}
