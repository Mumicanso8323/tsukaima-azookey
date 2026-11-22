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
/// 送信モード(work = バイト中など、細かく送る)は hub の応答 mode / mode_until で決まる。work の間は
/// startUpdatingLocation で監視を続け(裏で届けるには「常に」が要る)、届いた位置は最短2分おきに送る。
/// normal に戻る(応答で切り替わる・期限が過ぎる)と stopUpdatingLocation して、上の従来の経路に戻る。
/// モードは UserDefaults に保存し、起動時に復元する。hub が mode を返さないときは変えない。
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
        static let mode = "location.mode"
        static let modeUntil = "location.modeUntil"
    }

    /// 前面にいる間の間隔(約10分に1回。本人指定)
    private static let foregroundInterval: TimeInterval = 600
    /// work(バイト中)のとき、送る最短の間隔(本人指定の2分)
    private static let workMinInterval: TimeInterval = 120
    /// work のとき、この距離(m)動くまで位置を届けない(電池のため)
    private static let workDistanceFilter: CLLocationDistance = 50
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
                reconfigureForMode()
                startForegroundTimerIfNeeded()
            } else {
                manager.stopMonitoringSignificantLocationChanges()
                manager.stopMonitoringVisits()
                stopWorkUpdates()
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

    /// サーバー応答の送信モード。"work" か "normal"。work の期限(modeUntil)が過ぎたら normal と同じ扱い。
    private var mode: String
    private var modeUntil: Date?
    /// work の間、startUpdatingLocation で監視しているか
    private var isUpdatingForWork = false
    private var lastWorkFixAt: Date?
    private var workExpiryTimer: Timer?

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
        // 送信モードは起動のたびに保存済みの値から復元する(期限の判定は isWorkModeActive)
        mode = UserDefaults.standard.string(forKey: Key.mode) ?? "normal"
        modeUntil = UserDefaults.standard.object(forKey: Key.modeUntil) as? Date
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
        reconfigureForMode()
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

    // MARK: work(バイト中)の送信頻度。サーバー応答の mode で切り替える

    /// work の期限が未来の間だけ true。期限が過ぎたら normal と同じ扱いになる。
    private var isWorkModeActive: Bool {
        guard mode == "work", let until = modeUntil else { return false }
        return until > Date()
    }

    /// サーバー応答の mode / mode_until を保存し、監視の構成を合わせる。mode が無い応答(hub が古いとき)は何もしない。
    private func applyServerMode(_ response: Any) {
        guard let dict = response as? [String: Any], let serverMode = dict["mode"] as? String else { return }
        let newMode = serverMode == "work" ? "work" : "normal"
        var newUntil: Date?
        if newMode == "work", let text = dict["mode_until"] as? String {
            newUntil = ISO8601DateFormatter().date(from: text)
        }
        mode = newMode
        modeUntil = newUntil
        UserDefaults.standard.set(newMode, forKey: Key.mode)
        UserDefaults.standard.set(newUntil, forKey: Key.modeUntil)
        reconfigureForMode()
    }

    /// work のときは高頻度の監視を始め、normal(または期限切れ)のときは止めて従来の経路に戻す。何度呼んでも同じ結果になる。
    private func reconfigureForMode() {
        guard enabled, isWorkModeActive, canUseLocation else {
            stopWorkUpdates()
            return
        }
        startWorkUpdates()
    }

    private var canUseLocation: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    private func startWorkUpdates() {
        // 裏で届けるには「常に」が要る。使用中のみのときは前面の間だけ届く
        manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
        manager.pausesLocationUpdatesAutomatically = false
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = Self.workDistanceFilter
        manager.startUpdatingLocation()
        isUpdatingForWork = true
        scheduleWorkExpiry()
    }

    /// work の監視を止め、従来の経路(大きな移動・訪問・前面の10分おき)の設定に戻す。
    private func stopWorkUpdates() {
        workExpiryTimer?.invalidate()
        workExpiryTimer = nil
        guard isUpdatingForWork else { return }
        manager.stopUpdatingLocation()
        isUpdatingForWork = false
        lastWorkFixAt = nil
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// 期限が来たら、アプリが起きている間に normal へ戻す(裏で止まっていた場合は次に起きたとき・次の送信時に戻す)。
    private func scheduleWorkExpiry() {
        workExpiryTimer?.invalidate()
        workExpiryTimer = nil
        guard let until = modeUntil else { return }
        let interval = until.timeIntervalSinceNow
        guard interval > 0 else { return }
        workExpiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.reconfigureForMode()
        }
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
        // desiredAccuracy は触らない(normal のときは既定の Best、work のときは work の設定のまま)
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
                    let response = try await TsukaimaAPI.shared.sendJSON("POST", "/api/location", json: body)
                    self.applyServerMode(response)
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
        reconfigureForMode()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        if isUpdatingForWork {
            if isWorkModeActive {
                // work 中は届いた位置を最短 workMinInterval おきだけ送る(間の位置は捨てる。次の位置が新しいので)
                if let last = lastWorkFixAt, Date().timeIntervalSince(last) < Self.workMinInterval { return }
                lastWorkFixAt = Date()
            } else {
                reconfigureForMode()  // 期限が過ぎていた。normal に戻し、この1点は通常どおり送る
            }
        }
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
