import Foundation
import XCTest
@testable import azooKey

/// 11/12 15:51:59 の強制終了(0x8BADF00D「Failed to terminate gracefully after 5.0s」)の再発防止。
/// BT イヤホンの A2DP⇄HFP 切替中は AVAudioSession / AVAudioEngine の呼び出しが 4〜9 秒戻らない(端末ログで実測)。
/// それを main で待つと画面が固まり、その間に OS が終了を求めると 5 秒で殺される。
/// ここでは「開始処理が 3 秒かかる」状況を試験用のフックで作り、main が止まらないことを確かめる。
final class ConverseAudioIOThreadTests: XCTestCase {
    func testSlowAudioStartDoesNotBlockMainThread() {
        let io = ConverseAudioIO()
        let hookRan = expectation(description: "開始処理が音声キューで走った")
        let ranOnMain = LockedFlag()
        io.testHookBeforeStart = {
            ranOnMain.set(Thread.isMainThread)
            hookRan.fulfill()
            Thread.sleep(forTimeInterval: 3)  // BT の経路切替中の setActive / engine.start を模す
        }
        let done = XCTestExpectation(description: "開始の結果が main で返る")  // 待ちは XCTWaiter(落第にしない)
        let completedOnMain = LockedFlag()

        let t0 = Date()
        io.start(microphone: false) { _ in
            completedOnMain.set(Thread.isMainThread)
            done.fulfill()
        }
        let returnedAfter = Date().timeIntervalSince(t0)
        XCTAssertLessThan(returnedAfter, 0.2, "start は待たずに戻る(main をふさがない)")

        // 開始処理が 3 秒眠っている間も、main のキューは回り続ける(= 画面が固まらない・終了要求に応えられる)
        wait(for: [hookRan], timeout: 2)
        let mainTick = expectation(description: "開始処理の最中に main が動く")
        let tickAt = Date()
        DispatchQueue.main.async { mainTick.fulfill() }
        wait(for: [mainTick], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(tickAt), 0.5)

        XCTAssertFalse(ranOnMain.value, "開始処理は main 以外で走る")
        // 画面のないシミュレータでは本物の setActive / engine.start が戻らないことがあるので、結果待ちは落第にしない
        if XCTWaiter().wait(for: [done], timeout: 15) == .completed {
            XCTAssertTrue(completedOnMain.value, "結果は main で返す(ConverseEngine の状態は main で触る)")
        }
        io.stop()
    }

    func testStopReturnsImmediatelyEvenWhileStartIsSlow() {
        let io = ConverseAudioIO()
        let hookRan = expectation(description: "開始処理が始まった")
        io.testHookBeforeStart = {
            hookRan.fulfill()
            Thread.sleep(forTimeInterval: 2)
        }
        io.start(microphone: false) { _ in }
        wait(for: [hookRan], timeout: 2)
        let t0 = Date()
        io.stop()  // 開始処理の後ろに並ぶだけで、main では待たない
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.2)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
}
