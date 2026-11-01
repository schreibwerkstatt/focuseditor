//
//  SyncCadenceTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Regeln, wann der Sync von selbst läuft (SyncCadence): im Hintergrund
//  gedrosselt statt still, „manuell“ und „pausiert“ bleiben still.
//

import XCTest

final class SyncCadenceTests: XCTestCase {

    func testActiveWindowUsesChosenInterval() {
        XCTAssertEqual(SyncCadence.interval(mode: .active, isPaused: false, isActive: true), .seconds(5))
        XCTAssertEqual(SyncCadence.interval(mode: .relaxed, isPaused: false, isActive: true), .seconds(30))
    }

    /// Im Hintergrund läuft der Sync weiter — nie häufiger als `backgroundInterval`.
    func testBackgroundIsThrottledNotSilent() {
        XCTAssertEqual(SyncCadence.interval(mode: .active, isPaused: false, isActive: false),
                       SyncCadence.backgroundInterval)
        XCTAssertEqual(SyncCadence.interval(mode: .relaxed, isPaused: false, isActive: false),
                       SyncCadence.backgroundInterval)
    }

    func testManualAndPausedStaySilent() {
        for active in [true, false] {
            XCTAssertNil(SyncCadence.interval(mode: .manual, isPaused: false, isActive: active))
            XCTAssertNil(SyncCadence.interval(mode: .active, isPaused: true, isActive: active))
        }
        XCTAssertFalse(SyncCadence.autoEnabled(mode: .manual, isPaused: false))
        XCTAssertFalse(SyncCadence.autoEnabled(mode: .relaxed, isPaused: true))
        XCTAssertTrue(SyncCadence.autoEnabled(mode: .relaxed, isPaused: false))
    }

    /// Der letzte Push beim Beenden muss kürzer bleiben, als ein Nutzer auf ⌘Q wartet.
    func testQuitPushIsBounded() {
        XCTAssertLessThanOrEqual(SyncCadence.quitPushTimeout, .seconds(5))
    }
}
