import Foundation

/// hub の GET /api/auto/schedule(bot/autoschedule.py)の応答と、そこから「いま何をするか」を決める純粋関数。
/// 授業の自動録音(開始)と、技能教習中の消音(残り秒数)の両方が使う。
struct TsukaimaAutoSchedule: Equatable {
    struct ClassSession: Equatable {
        let title: String
        let start: Date
        let end: Date
    }

    /// 技能教習(連続コマはまとめた一続き)
    struct Driving: Equatable {
        let active: Bool
        let until: Date?
        let nextStart: Date?
        let nextUntil: Date?
    }

    let now: Date
    let classes: [ClassSession]
    let driving: Driving

    /// 授業の開始のこれだけ前から録音を始めてよい(サーバーの current_course と同じ15分)
    static let classLeadTime: TimeInterval = 15 * 60
    /// 技能教習の開始のこれだけ前に着いていたら、もう消音にする
    static let drivingLeadTime: TimeInterval = 15 * 60

    static func parse(_ data: Data) -> TsukaimaAutoSchedule? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let now = date(o["now"]) else { return nil }
        let classes: [ClassSession] = (o["classes"] as? [[String: Any]] ?? []).compactMap {
            guard let t = $0["title"] as? String, let s = date($0["start"]), let e = date($0["end"]) else { return nil }
            return ClassSession(title: t, start: s, end: e)
        }
        let d = o["driving"] as? [String: Any] ?? [:]
        let driving = Driving(active: d["active"] as? Bool ?? false, until: date(d["until"]),
                              nextStart: date(d["next_start"]), nextUntil: date(d["next_until"]))
        return TsukaimaAutoSchedule(now: now, classes: classes, driving: driving)
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// いま録音を始めるべき授業(開始15分前〜終了まで)。無ければ nil = 何もしない
    func classToRecord(at t: Date) -> ClassSession? {
        classes.first { $0.start.addingTimeInterval(-Self.classLeadTime) <= t && t < $0.end }
    }

    /// 消音を続ける残り秒数。技能教習の最中か、開始15分前までに入っているときだけ正。学科だけなら 0。
    func silenceSeconds(at t: Date) -> Int {
        if driving.active, let u = driving.until { return max(0, Int(u.timeIntervalSince(t))) }
        if let s = driving.nextStart, let u = driving.nextUntil, s.timeIntervalSince(t) <= Self.drivingLeadTime {
            return max(0, Int(u.timeIntervalSince(t)))
        }
        return 0
    }
}
