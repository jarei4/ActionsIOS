// Config.swift — 编译期注入的运行期配置（随描述文件一起进包，可审计）
import Foundation

enum AppConfig {
    /// 由 Info.plist 的 API_BASE_URL 提供，值来自构建设置 API_BASE_URL。
    /// 换服务器不需要改代码：xcodebuild API_BASE_URL=http://192.168.1.20:8787
    static var apiBaseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           let url = URL(string: raw.trimmed),
           url.scheme == "http" || url.scheme == "https",
           url.host != nil {
            return url
        }
        return URL(string: "http://127.0.0.1:8787")!
    }

    static var apiBaseDisplay: String {
        let s = apiBaseURL.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    static let cookieName = "aurora_rt"

    static var marketingVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    static var versionLabel: String { "v\(marketingVersion) (\(buildNumber))" }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.yg.aurora"
    }

    /// 安装来源，用于设置页展示签名状态（同一份代码不同签名渠道可以不同表现）
    static var distributionChannel: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
