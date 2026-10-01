import AVFoundation
import Combine
import Foundation
import Speech

/// Claude タブの音声入力(会話モードではない): 押して話す→止めると文字にして入力欄のカーソル位置に差し込むだけ。
/// 送信はしない・カーソルは外さない。認識は hub の `/api/stt/once`(会話モードと同じ stt)、
/// 圏外などで失敗したら iOS の SFSpeechRecognizer(ja-JP)に切り替える。
/// マイクは講義録音と同じ TsukaimaMic(16kHz mono Float32)。講義録音・会話モードの最中は始めない。
@MainActor
final class ClaudeVoiceInput: ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing }

    @Published private(set) var phase = Phase.idle
    @Published var errorText: String?

    private let mic = TsukaimaMic()
    private let buffer = SampleBuffer()

    /// tap スレッドから足して main で取り出すので、main actor の外に置く
    private final class SampleBuffer: @unchecked Sendable {
        private var samples: [Float] = []
        private let lock = NSLock()
        func append(_ data: Data) {
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            lock.lock(); samples.append(contentsOf: floats); lock.unlock()
        }
        func take() -> [Float] {
            lock.lock(); defer { lock.unlock() }
            let s = samples; samples = []
            return s
        }
    }

    init() {
        let buffer = self.buffer
        mic.onChunk = { data in buffer.append(data) }
        mic.onError = { [weak self] msg in
            Task { @MainActor in self?.errorText = msg }
        }
    }

    /// 開始/停止のトグル(ボタンと ⌘⇧M の両方から)。停止したら文字起こしして `insert` に渡す
    func toggle(insert: @escaping @MainActor (String) -> Void) {
        switch phase {
        case .idle:
            start()
        case .recording:
            stopAndTranscribe(insert: insert)
        case .transcribing:
            break
        }
    }

    private func start() {
        guard !TsukaimaMic.active, ConverseEngine.shared.phase == .stopped else {
            errorText = "録音中・会話モード中は音声入力を使えません"
            return
        }
        AVAudioApplication.requestRecordPermission { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                guard ok else { self.errorText = "マイクの使用が許可されていません"; return }
                _ = self.buffer.take()
                do {
                    try self.mic.start()
                    self.phase = .recording
                } catch {
                    self.errorText = "マイクを開けませんでした"
                }
            }
        }
    }

    private func stopAndTranscribe(insert: @escaping @MainActor (String) -> Void) {
        mic.stop()
        let s = buffer.take()
        phase = .transcribing
        Task { @MainActor in
            defer { phase = .idle }
            guard s.count > Int(TsukaimaConfig.sampleRate / 2) else { return }  // 0.5 秒未満は無音扱い
            let pcm = Self.pcm16(s)
            if let text = try? await ClaudeSession.shared.transcribeOnce(pcm16: pcm) {
                if !text.isEmpty { insert(text) }
                return
            }
            // hub に届かない → 端末内の認識(ja-JP)
            do {
                let text = try await Self.recognizeOnDevice(pcm16: pcm)
                if !text.isEmpty { insert(text) }
            } catch {
                errorText = "文字起こしに失敗しました"
            }
        }
    }

    /// Float32 → PCM16LE(hub の /api/stt/once の形)
    nonisolated static func pcm16(_ s: [Float]) -> Data {
        var out = Data(capacity: s.count * 2)
        for v in s {
            let c = max(-1, min(1, v))
            var i = Int16(c * 32767)
            withUnsafeBytes(of: &i) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// PCM16LE 16kHz mono を WAV にして SFSpeechRecognizer(ja-JP)にかける
    nonisolated static func recognizeOnDevice(pcm16: Data) async throws -> String {
        let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard granted, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizer.isAvailable else {
            throw NSError(domain: "claude.voice", code: 1)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-voice-\(UUID().uuidString).wav")
        try wav(pcm16: pcm16, rate: Int(TsukaimaConfig.sampleRate)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                guard !once.done else { return }
                if let error { once.done = true; c.resume(throwing: error); return }
                if let result, result.isFinal { once.done = true; c.resume(returning: result.bestTranscription.formattedString) }
            }
        }
    }

    nonisolated static func wav(pcm16: Data, rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm16.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm16.count)); d.append(pcm16)
        return d
    }
}
