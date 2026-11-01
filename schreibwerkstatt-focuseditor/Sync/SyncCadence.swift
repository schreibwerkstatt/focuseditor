//
//  SyncCadence.swift
//  schreibwerkstatt-focuseditor
//
//  Wann die SyncEngine von selbst synchronisiert — als reine Regeln, damit sie
//  ohne laufende Engine testbar sind.
//
//  Warum der Sync auch im Hintergrund läuft: liegt ein anderes Fenster vorn
//  (Browser, Mail), war der Sync früher ganz still. Eigene Edits blieben in der
//  Outbox, fremde (Web-App, zweites Gerät) kamen nicht herein — und wer dann den
//  Deckel zuklappt, nimmt einen veralteten Stand mit, während das andere Gerät
//  auf dem alten Server-Stand weiterschreibt (mehr Konflikte). Im Hintergrund
//  läuft der Tick darum gedrosselt weiter (`backgroundInterval`); „manuell“ und
//  „pausiert“ bleiben ganz still.
//
//  Warum direkt nach dem Speichern gepusht wird: der Poll-Takt (5/30/60 s) ist
//  für das HOLEN gedacht. Ein Edit, der bis zum nächsten Tick in der Outbox
//  liegt, ist für jedes andere Gerät unsichtbar — und genau in diesem Fenster
//  entstehen Konflikte. `saveSyncDelay` entprellt: der Editor speichert
//  ohnehin nur nach einer Tipp-Pause, mehrere Saves kurz hintereinander geben
//  einen Tick.
//

import Foundation

enum SyncCadence {
    /// Poll-Periode, solange kein Fenster der App vorn liegt.
    static let backgroundInterval: Duration = .seconds(60)
    /// Entprellung zwischen lokalem Save und dem Push-Tick.
    static let saveSyncDelay: Duration = .milliseconds(1500)
    /// Frist für den letzten Push beim Beenden (⌘Q). Danach beendet die App
    /// trotzdem — die Outbox bleibt erhalten und geht beim nächsten Start raus.
    static let quitPushTimeout: Duration = .seconds(4)

    /// Läuft der automatische Sync überhaupt? „Manuell“ und „pausiert“ sind
    /// still — auch für den Push nach dem Speichern und beim Beenden.
    static func autoEnabled(mode: SyncPollMode, isPaused: Bool) -> Bool {
        !isPaused && mode.interval != nil
    }

    /// Poll-Periode für den aktuellen Zustand; `nil` = kein Loop. Im Hintergrund
    /// nie häufiger als `backgroundInterval`.
    static func interval(mode: SyncPollMode, isPaused: Bool, isActive: Bool) -> Duration? {
        guard autoEnabled(mode: mode, isPaused: isPaused), let base = mode.interval else { return nil }
        return isActive ? base : max(base, backgroundInterval)
    }
}
