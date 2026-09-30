import BackgroundTasks
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// 写真ライブラリの自動バックアップ(設定でON時のみ)。アプリを開いたとき・前面に戻ったとき、
/// および(PHPhotoLibraryChangeObserver が拾える範囲で)ライブラリに変化があったときに、
/// hub の POST /api/photos/intake へ新しい写真・スクリーンショットを送る。
///
/// 送る範囲は「有効にした時点(enabledAt)より後に撮った/追加された分だけ」— 初回に既存の
/// ライブラリを遡って全部送ることはしない(依頼どおり)。
///
/// 重複防止は localIdentifier ベースの watermark(TsukaimaLocationService と同じ「送れた分だけ進める」
/// 流儀): creationDate の最大値と、その時刻ちょうどの写真で送信済みの localIdentifier 集合を
/// UserDefaults に持つ。同時刻の写真が複数あっても二重送信しない。送信に失敗した写真より後ろは
/// watermark を進めないので、次回また同じ写真から再送を試みる。サーバ側 local_id の UNIQUE 制約が
/// 最終防波堤(TsukaimaPhotoBackupTests 相当の保険。bot/photos.py 参照)。
///
/// バックグラウンドは BGAppRefreshTask で best-effort に叩く(iOS の裁量任せ。確実性は保証しない)。
/// 確実に動くのは「アプリを開いたとき」で、依頼文の主目的もそちら。
@MainActor
final class TsukaimaPhotoBackup: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = TsukaimaPhotoBackup()

    static let backgroundTaskIdentifier = "jp.yusukedoi.tsukaima.azookey.photoBackup"

    private enum Key {
        static let enabled = "photoBackup.enabled"
        static let enabledAt = "photoBackup.enabledAt"
        static let watermark = "photoBackup.watermark"
        static let watermarkIDs = "photoBackup.watermarkIDs"
        static let lastSyncAt = "photoBackup.lastSyncAt"
    }

    /// 設定画面のオン/オフ。オンにした瞬間に権限を求め、以後 enabledAt を基準に動き出す。
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: Key.enabled) {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Key.enabled)
            if enabled {
                Task { await turnOn() }
            } else {
                stopObservingLibrary()
            }
        }
    }

    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false

    private var observing = false
    private var running = false
    /// 実行中にもう1回変化が来たら、終わり次第もう1周する(取りこぼし防止)
    private var pendingRerun = false

    private override init() {
        super.init()
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if let stamp = UserDefaults.standard.object(forKey: Key.lastSyncAt) as? Date {
            lastSyncAt = stamp
        }
    }

    // MARK: 起動時・前面復帰のたびに呼ぶ(AppTabView の scenePhase == .active。冪等)

    func applicationDidLaunchOrForeground() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard enabled else { return }
        startObservingLibraryIfNeeded()
        Task { await syncIfPossible() }
    }

    func applicationDidEnterBackground() {
        scheduleBackgroundRefresh()
    }

    /// 設定画面で「許可されていません」のとき、設定アプリへの案内を出すためのフラグ
    var needsSettingsAppUpgrade: Bool {
        enabled && (authorizationStatus == .denied || authorizationStatus == .restricted)
    }

    // MARK: ON にする

    private func turnOn() async {
        let status = await Self.requestAuthorizationIfNeeded()
        authorizationStatus = status
        guard status == .authorized || status == .limited else {
            // 許可が取れなかったらトグルを戻す(権限ダイアログを何度も出さない)
            enabled = false
            return
        }
        // 初回のみ enabledAt を打つ = ここから先だけが対象(既存の写真は遡らない)
        if UserDefaults.standard.object(forKey: Key.enabledAt) == nil {
            let now = Date()
            UserDefaults.standard.set(now, forKey: Key.enabledAt)
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Key.watermark)
        }
        startObservingLibraryIfNeeded()
        await syncIfPossible()
    }

    private static func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: ライブラリの変化を拾う(プロセスが生きている間だけ。バックグラウンド常駐は保証しない)

    private func startObservingLibraryIfNeeded() {
        guard !observing else { return }
        observing = true
        PHPhotoLibrary.shared().register(self)
    }

    private func stopObservingLibrary() {
        guard observing else { return }
        observing = false
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: 同期本体

    private func syncIfPossible() async {
        guard enabled, !running else {
            if running { pendingRerun = true }
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        running = true
        isSyncing = true
        defer {
            running = false
            isSyncing = false
            if pendingRerun {
                pendingRerun = false
                Task { await self.syncIfPossible() }
            }
        }
        await sync()
    }

    private func sync() async {
        let watermarkStamp = UserDefaults.standard.double(forKey: Key.watermark)
        guard watermarkStamp > 0 else { return }  // enabledAt がまだ無い = 有効化されていない
        let watermark = Date(timeIntervalSince1970: watermarkStamp)
        let tieIDs = Set(UserDefaults.standard.stringArray(forKey: Key.watermarkIDs) ?? [])

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@",
                                        PHAssetMediaType.image.rawValue, watermark as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)

        var toSend: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            guard let created = asset.creationDate else { return }
            if created < watermark { return }
            if created == watermark, tieIDs.contains(asset.localIdentifier) { return }
            toSend.append(asset)
        }
        guard !toSend.isEmpty else { return }

        var newWatermark = watermark
        var newTieIDs = tieIDs

        for asset in toSend {
            guard let created = asset.creationDate else { continue }
            guard let exported = await Self.exportData(for: asset) else { continue }
            let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
            let ok = await Self.upload(exported, localID: asset.localIdentifier, takenAt: created, isScreenshot: isScreenshot)
            guard ok else {
                lastError = "写真の送信に失敗しました(次回また試します)"
                break  // これ以降は次回に回す(順序が creationDate 昇順なので watermark は正しく途中で止まる)
            }
            lastError = nil
            if created > newWatermark {
                newWatermark = created
                newTieIDs = [asset.localIdentifier]
            } else if created == newWatermark {
                newTieIDs.insert(asset.localIdentifier)
            }
            UserDefaults.standard.set(newWatermark.timeIntervalSince1970, forKey: Key.watermark)
            UserDefaults.standard.set(Array(newTieIDs), forKey: Key.watermarkIDs)
        }
        lastSyncAt = Date()
        UserDefaults.standard.set(lastSyncAt, forKey: Key.lastSyncAt)
    }

    // MARK: PHAsset → バイト列(元ファイルのまま。HEIC 等を変換しない)

    private struct Exported {
        var data: Data
        var filename: String
        var mime: String
    }

    private static func exportData(for asset: PHAsset) async -> Exported? {
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) else { return nil }
        let filename = resource.originalFilename
        let mime = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // iCloud 上にしか無い写真も落とせるように
        var data = Data()
        return await withCheckedContinuation { cont in
            PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                data.append(chunk)
            }, completionHandler: { error in
                if error != nil {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Exported(data: data, filename: filename, mime: mime))
                }
            })
        }
    }

    // MARK: アップロード(既存の TsukaimaAPI.upload をそのまま使う。/api/photos/intake は bot/photos.py)

    private static func upload(_ exported: Exported, localID: String, takenAt: Date, isScreenshot: Bool) async -> Bool {
        let fields: [String: String] = [
            "local_id": localID,
            "taken_at": ISO8601DateFormatter().string(from: takenAt),
            "is_screenshot": isScreenshot ? "1" : "0",
            "device": UIDevice.current.name,
        ]
        do {
            _ = try await TsukaimaAPI.shared.upload("/api/photos/intake", data: exported.data,
                                                    filename: exported.filename, mime: exported.mime, fields: fields)
            return true
        } catch {
            TsukaimaLog.add("photoBackup upload failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: バックグラウンド更新(best-effort。確実性は保証しない。BGTaskScheduler の登録は AppDelegate)

    func scheduleBackgroundRefresh() {
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// AppDelegate から: BGAppRefreshTask のハンドラ本体
    func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()  // 次回分をまず予約しておく(このタスクが打ち切られても途切れないように)
        let work = Task {
            await syncIfPossible()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}

extension TsukaimaPhotoBackup: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            await self.syncIfPossible()
        }
    }
}
