import Foundation

/// ConverseAudioIO.restart() の「ループの歯止め」(純粋なロジック。時計は呼び出し側が渡す)。
/// - 直近 `window` 秒の再起動要求が `freeCount` 回以内: 今までどおり即時。
/// - それを超えたら(= 経路が揺れている): `baseWait` 秒待ってから 1 回だけ再起動する。待っている間に来た要求は 1 回に合流する。
///   それでも続いて直近の要求が `longCount` 回以上になったら待ちを `maxWait` 秒に伸ばす。
/// - `window` 秒より長く要求が止まれば、通常(即時)に戻る。
/// - stop などで `cancel()` すると世代が進み、待っていた古い再起動は捨てられる。
struct ConverseRestartDamper {
    enum Decision: Equatable {
        case immediate
        case delay(Double)
        case merged
    }

    static let window = 10.0
    static let freeCount = 3
    static let longCount = 7
    static let baseWait = 1.5
    static let maxWait = 3.0

    private var times: [Double] = []
    private var pending = false
    /// 待ちを予約するときに控える世代。cancel() で進む。
    private(set) var generation = 0

    /// 直近 `window` 秒の要求の数(今回を含む。request の直後に読む)
    var recentCount: Int { times.count }

    /// 再起動の要求 1 件。どの契機(構成変更・経路変更・割り込み・リトライ)でも入口で 1 回呼ぶ。
    mutating func request(now: Double) -> Decision {
        times.removeAll { now - $0 > Self.window }
        times.append(now)
        if pending { return .merged }
        guard times.count > Self.freeCount else { return .immediate }
        pending = true
        return .delay(times.count >= Self.longCount ? Self.maxWait : Self.baseWait)
    }

    /// 待ちが終わったとき。予約した世代のままで、まだ待っていれば true(= 再起動してよい)。
    mutating func fire(generation g: Int) -> Bool {
        guard g == generation, pending else { return false }
        pending = false
        return true
    }

    /// 停止・別オーナーが握った: 待ちと履歴を捨てる。
    mutating func cancel() {
        generation += 1
        pending = false
        times.removeAll()
    }
}
