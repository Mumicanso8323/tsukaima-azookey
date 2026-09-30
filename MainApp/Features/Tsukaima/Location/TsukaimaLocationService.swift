import CoreLocation
import Foundation

/// 位置情報を hub(portal-bot, bot/location.py)の POST /api/location {lat, lon, acc, at} へ送る。
/// 認証は /api/presence と同じ(TsukaimaEndpoint/TsukaimaAPI が付ける、端末の合鍵または自動化トークン)。
/// main スレッド専用(TsukaimaAlarm/TsukaimaRecorderEngine と同じ流儀。CLLocationManager の delegate
/// 呼び出しは、生成したスレッド=main で届く)。
///
/// 電池に優しい経路だけを使う:
/// - アプリを閉じていても届く「大きな移動」(startMonitoringSignificantLocationChanges)と
///   「訪問」(startMonitoringVisits)。どちらも Always 許可が要るが、追加の UIBackgroundModes は不要。
/// - アプリが前面にある間だけ、約10分に1回、精度を上げて1点取る(requestLocation)。
///
/// 許可はまず使用中(WhenInUse)を求め、それが得られたら常に(Always)を1回だけ追加で求める
/// (本人指定の順番。設定でオンにしたときと、起動のたびに許可状況を見て進める)。
///
/// 送れた位置は最後に送った時刻を UserDefaults に覚える。送れなかった分は同じく UserDefaults に
/// 溜め(TsukaimaLog と同じ流儀)、次に送れたときにまとめて送る。
///
/// 起動時・前面復帰・(位置イベントで)裏から起こされ直したとき、すべて
/// `applicationDidLaunchOrForeground()` を呼べば冪等に監視を再開する(AppDelegate / AppTabView から)。
final class TsukaimaLocationService: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = TsukaimaLocationService()

    private enum Key {
        static let enabled = "location.enabled"
        static let lastSentAt = "location.lastSentAt"
        static let queue = "location.pendingQueue"
        static let askedAlways = "location.askedAlways"
    }

    /// 前面にいる間の間隔(約10分に1回。本人指定)
    private static let foregroundInterval: TimeInterval = 600
    /// オフライン時に溜め込む上限件数(際限なく溜めない)
    private static let maxQueue = 200

    /// 設定画面のオン/オフ。オンにした瞬間に許可を求め、監視を始める。
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: Key.enabled) {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Key.enabled)
            if enabled {
                beginAuthorizationFlowIfNeeded()
                resumeMonitoringIfPossible()
                startForegroundTimerIfNeeded()
            } else {
                manager.stopMonitoringSignificantLocationChanges()
                manager.stopMonitoringVisits()
                stopForegroundTimer()
            }
        }
    }

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastSentAt: Date?
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()
    private var foregroundTimer: Timer?
    private var lastForegroundFixAt: Date?
    private var flushing = false

    private struct PendingFix: Codable {
        var lat: Double
        var lon: Double
        var acc: Double?
        var at: String
    }

    private override init() {
        authorizationStatus = .notDetermined
        if let stamp = UserDefaults.standard.object(forKey: Key.lastSentAt) as? Date {
            lastSentAt = stamp
        }
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: 起動時・前面復帰・バックグラウンド再起動のたびに呼ぶ(冪等)

    /// AppDelegate.didFinishLaunching と、前面復帰(AppTabView の scenePhase == .active)の両方から呼ぶ。
    func applicationDidLaunchOrForeground() {
        authorizationStatus = manager.authorizationStatus
        guard enabled else { return }
        beginAuthorizationFlowIfNeeded()
        resumeMonitoringIfPossible()
        maybeTakeForegroundFix()
        startForegroundTimerIfNeeded()
        flushQueue()
    }

    func applicationDidEnterBackground() {
        stopForegroundTimer()
    }

    /// 設定画面で「使用中のみ」のとき、設定アプリへの案内を出すためのフラグ
    var needsAlwaysUpgrade: Bool { enabled && authorizationStatus == .authorizedWhenInUse }

    // MARK: 許可

    private func beginAuthorizationFlowIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            requestAlwaysIfNotAskedYet()
        default:
            break
        }
    }

    private func requestAlwaysIfNotAskedYet() {
        guard !UserDefaults.standard.bool(forKey: Key.askedAlways) else { return }
        UserDefaults.standard.set(true, forKey: Key.askedAlways)
        manager.requestAlwaysAuthorization()
    }

    // MARK: 監視の開始(電池に優しい経路だけ。Always 必須)

    private func resumeMonitoringIfPossible() {
        guard enabled, manager.authorizationStatus == .authorizedAlways else { return }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startMonitoringVisits()
    }

    // MARK: 前面にいる間、約10分に1回だけ精度を上げて取る

    private func startForegroundTimerIfNeeded() {
        guard enabled, foregroundTimer == nil else { return }
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: Self.foregroundInterval, repeats: true) { [weak self] _ in
            self?.maybeTakeForegroundFix()
        }
    }

    private func stopForegroundTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    private func maybeTakeForegroundFix() {
        guard enabled else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        if let last = lastForegroundFixAt, Date().timeIntervalSince(last) < Self.foregroundInterval - 5 {
            return
        }
        lastForegroundFixAt = Date()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestLocation()
    }

    // MARK: 送信・オフラインキュー

    private func recordFix(lat: Double, lon: Double, acc: Double?, at: Date) {
        enqueue(PendingFix(lat: lat, lon: lon, acc: acc, at: ISO8601DateFormatter().string(from: at)))
        flushQueue()
    }

    private func enqueue(_ fix: PendingFix) {
        var q = loadQueue()
        q.append(fix)
        if q.count > Self.maxQueue { q.removeFirst(q.count - Self.maxQueue) }
        saveQueue(q)
    }

    private func loadQueue() -> [PendingFix] {
        guard let data = UserDefaults.standard.data(forKey: Key.queue),
              let q = try? JSONDecoder().decode([PendingFix].self, from: data) else { return [] }
        return q
    }

    private func saveQueue(_ q: [PendingFix]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(q), forKey: Key.queue)
    }

    /// 溜まっている分を古い順にまとめて送る。オフライン等で失敗したらそこで止め、残りは次回に回す
    /// (毎回全部作り直すと成功した分まで壊れるので、送れた分だけキューから消す)。
    /// TsukaimaAPI が @MainActor なので、ここだけ明示的に main へ寄せて呼ぶ。
    private func flushQueue() {
        guard !flushing else { return }
        guard !loadQueue().isEmpty else { return }
        flushing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var q = self.loadQueue()
            while !q.isEmpty {
                let fix = q[0]
                var body: [String: Any] = ["lat": fix.lat, "lon": fix.lon, "at": fix.at]
                if let acc = fix.acc { body["acc"] = acc }
                do {
                    _ = try await TsukaimaAPI.shared.sendJSON("POST", "/api/location", json: body)
                    q.removeFirst()
                    self.saveQueue(q)
                    self.lastSentAt = Date()
                    UserDefaults.standard.set(self.lastSentAt, forKey: Key.lastSentAt)
                    self.lastError = nil
                } catch {
                    self.lastError = error.localizedDescription
                    break
                }
            }
            self.flushing = false
        }
    }
}

extension TsukaimaLocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard enabled else { return }
        if authorizationStatus == .authorizedWhenInUse {
            requestAlwaysIfNotAskedYet()
        }
        resumeMonitoringIfPossible()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let acc: Double? = loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
        recordFix(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, acc: acc, at: loc.timestamp)
    }

    /// 「訪問」(到着・出発)の通知。出発時刻が分かっていればそれを、分からなければ到着時刻・それも
    /// 分からなければ「今」を at にする(CLVisit は不明な方に .distantPast/.distantFuture を入れてくる)。
    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let acc: Double? = visit.horizontalAccuracy >= 0 ? visit.horizontalAccuracy : nil
        let at: Date
        if visit.departureDate != .distantFuture {
            at = visit.departureDate
        } else if visit.arrivalDate != .distantPast {
            at = visit.arrivalDate
        } else {
            at = Date()
        }
        recordFix(lat: visit.coordinate.latitude, lon: visit.coordinate.longitude, acc: acc, at: at)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
    }
}
