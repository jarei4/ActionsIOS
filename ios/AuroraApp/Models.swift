// Models.swift — 与服务端 JSON 一一对应（时间戳统一为毫秒）
import Foundation

enum NoteStatus: String, Codable, CaseIterable, Identifiable {
    case open
    case done

    var id: String { rawValue }

    var label: String { self == .open ? "待办" : "完成" }
}

struct Note: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var body: String
    var status: NoteStatus
    var priority: Int
    var due: Double?
    var tags: [String]
    var pinned: Bool
    var rev: Int
    var createdAt: Double
    var updatedAt: Double

    var dueDate: Date? {
        guard let due else { return nil }
        return Date(timeIntervalSince1970: due / 1000)
    }

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    var isOverdue: Bool {
        guard status == .open, let date = dueDate else { return false }
        return date < Date()
    }

    var preview: String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "还没有正文" : text
    }

    var priorityLabel: String {
        switch priority {
        case 2: return "紧急"
        case 0: return "稍后"
        default: return "常规"
        }
    }
}

struct User: Codable, Identifiable, Hashable {
    let id: String
    var email: String
    var role: String
    var createdAt: Double?

    var isOwner: Bool { role == "owner" }

    var displayName: String {
        let name = email.split(separator: "@").first.map(String.init) ?? email
        return name.isEmpty ? "旅行者" : name
    }

    var initial: String { String(displayName.prefix(1)).uppercased() }

    var roleLabel: String { isOwner ? "主控" : "成员" }
}

struct Stats: Codable, Hashable {
    var total: Int = 0
    var done: Int = 0
    var open: Int = 0
    var urgent: Int = 0
    var overdue: Int = 0

    var progress: Double {
        total == 0 ? 0 : min(1, Double(done) / Double(total))
    }
}

/* ── 传输封套 ─────────────────────────────────────────────── */
struct Session: Codable {
    var access: String
    var expiresIn: Int
    var user: User
}

struct MeEnvelope: Codable { var user: User }
struct NotesEnvelope: Codable { var notes: [Note] }
struct NoteEnvelope: Codable { var note: Note }
struct ErrorEnvelope: Codable {
    var error: String?
    var code: String?
}

/* ── 写入载荷 ─────────────────────────────────────────────── */
struct NewNote: Encodable {
    var title: String
    var body: String
    var priority: Int
    var tags: [String]
    var due: Double?
}

/// PATCH 只发送真正变更的字段：
/// 服务端把 `undefined` 视为“不改”，把 `null` 视为“清空”，两者语义不同。
struct NotePatch: Encodable {
    var title: String? = nil
    var body: String? = nil
    var status: String? = nil
    var priority: Int? = nil
    var tags: [String]? = nil
    var dueMS: Double? = nil
    var clearDue: Bool = false
    var pinned: Bool? = nil
    var rev: Int? = nil

    enum CodingKeys: String, CodingKey {
        case title, body, status, priority, tags, due, pinned, rev
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(pinned, forKey: .pinned)
        try c.encodeIfPresent(rev, forKey: .rev)
        if clearDue {
            try c.encodeNil(forKey: .due)
        } else if let dueMS {
            try c.encode(dueMS, forKey: .due)
        }
    }
}
