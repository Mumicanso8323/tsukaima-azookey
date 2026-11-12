import Foundation
import XCTest
@testable import azooKey

/// 11/12 15:51:59 の強制終了(0x8BADF00D「Failed to terminate gracefully after 5.0s」)の再発防止。
/// BT イヤホンの A2DP⇄HFP 切替中は AVAudioSession / AVAudioEngine の呼び出しが 4〜9 秒戻らない(端末ログで実測)。
/// それを main で待つと画面が固まり、その間に OS が終了を求めると 5 秒で殺される。
/// ここでは「開始処理が 3 秒かかる」状況を試験用の本体(testStartBody)で作り、main が止まらないことを確かめる。
/// 本物の音声サーバーには触れない(CI のシミュレータでは CoreAudio の初期化が「RPC timeout」で落ちることがある)。
final class ConverseAudioIOThreadTests: XCTestCase {
    private struct Boom: Error {}

    func testSlowAudioStartDoesNotBlockMainThread() {
        let io = ConverseAudioIO()
        let bodyRan = expectation(description: "開始処理が音声キューで走った")
        let ranOnMain = LockedFlag()
        io.testStartBody = {
            ranOnMain.set(Thread.isMainThread)
            bodyRan.fulfill()
            Thread.sleep(forTimeInterval: 3)  // BT の経路切替中の setActive / engine.start を模す
        }
        let done = expectation(description: "開始の結果が main で返る")
        let completedOnMain = LockedFlag()
        let gotError = LockedFlag()

        let t0 = Date()
        io.start(microphone: true) { error in
            completedOnMain.set(Thread.isMainThread)
            gotError.set(error != nil)
            done.fulfill()
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.2, "start は待たずに戻る(main をふさがない)")

        // 開始処理が 3 秒眠っている間も、main のキューは回り続ける(= 画面が固まらない・終了要求に応えられる)
        wait(for: [bodyRan], timeout: 2)
        let mainTick = expectation(description: "開始処理の最中に main が動く")
        DispatchQueue.main.async { mainTick.fulfill() }
        wait(for: [mainTick], timeout: 0.5)

        wait(for: [done], timeout: 10)
        XCTAssertFalse(ranOnMain.value, "開始処理は main 以外で走る")
        XCTAssertTrue(completedOnMain.value, "結果は main で返す(ConverseEngine の状態は main で触る)")
        XCTAssertFalse(gotError.value)
    }

    func testStartFailureIsReportedOnMain() {
        let io = ConverseAudioIO()
        io.testStartBody = { throw Boom() }
        let done = expectation(description: "失敗が main で返る")
        let onMain = LockedFlag()
        let gotError = LockedFlag()
        io.start(microphone: true) { error in
            onMain.set(Thread.isMainThread)
            gotError.set(error is Boom)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(onMain.value)
        XCTAssertTrue(gotError.value)
    }

    func testStopReturnsImmediatelyEvenWhileStartIsSlow() {
        let io = ConverseAudioIO()
        let bodyRan = expectation(description: "開始処理が始まった")
        io.testStartBody = {
            bodyRan.fulfill()
            Thread.sleep(forTimeInterval: 2)
        }
        let done = expectation(description: "開始が終わった")
        io.start(microphone: true) { _ in done.fulfill() }
        wait(for: [bodyRan], timeout: 2)
        let t0 = Date()
        io.stop()  // 開始処理の後ろに並ぶだけで、main では待たない
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.2)
        wait(for: [done], timeout: 5)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
}
