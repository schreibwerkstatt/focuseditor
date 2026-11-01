//
//  AppTerminationGuard.swift
//  schreibwerkstatt-focuseditor
//
//  Beenden (⌘Q) ohne Textverlust: sichert den offenen Draft, BEVOR der Prozess
//  geht.
//
//  Warum es das braucht: der Editor-Autosave läuft entprellt (500–5000 ms,
//  Einstellungen → Schreiben). Zwischen dem letzten Tastenanschlag und dem
//  Autosave-Tick liegt der frische Text nur im DOM der WKWebView — nicht im
//  LocalStore. ⌘Q in diesem Fenster verwarf ihn bisher ersatzlos: der
//  `WritingTimeTracker` hängt an `willTerminate`, der Draft-Flush hing nirgends,
//  und `scenePhase` liefert beim Beenden keinen verlässlichen Wechsel (derselbe
//  Grund, aus dem die Schreibzeit dort schon selbst nachfasst).
//
//  Mechanik: `applicationShouldTerminate` ist der EINZIGE Ort, an dem AppKit
//  das Beenden noch aufhalten kann. `willTerminate` ist zu spät und synchron —
//  ein `await` darin liefe nie zu Ende, und ein blockierendes Warten auf den
//  MainActor würde den JS-Callback der WebView aussperren (Deadlock). Also
//  `.terminateLater` + asynchroner Flush + `reply(toApplicationShouldTerminate:)`.
//
//  Der Flush ist eng befristet (`EditorBridge.quitFlushTimeout`, 2 s): er macht
//  einen JS-Roundtrip plus einen SQLite-Write, kein Netz. Antwortet die WebView
//  nicht, wird trotzdem beendet — ein Beenden, das hängt, wäre die schlechtere
//  Krankheit, und der JS-seitige `blur`-Flush (WebAssets+IndexHTML) hat den
//  Stand bei einem Fensterwechsel ohnehin schon gesichert.
//
//  Danach folgt ein ebenso befristeter letzter Push (`SyncEngine.pushBeforeQuit`,
//  `SyncCadence.quitPushTimeout`), damit andere Geräte den Stand haben. Er läuft
//  nur bei automatischem Sync und vorhandener Outbox; bleibt der Server aus, geht
//  die Outbox beim nächsten Start raus.
//

import AppKit

/// App-Delegate mit genau einer Aufgabe: den offenen Draft vor dem Beenden
/// sichern. Bewusst kein Sammelbecken — alles andere hängt an SwiftUI-Szenen.
final class AppTerminationGuard: NSObject, NSApplicationDelegate {

    /// Wird vor dem Beenden erledigt. Setzt der App-`task`, sobald `AppCore`
    /// steht (der Delegate wird von SwiftUI vor `AppCore` erzeugt und kennt es
    /// darum nicht selbst). Ohne gesetzten Wert beendet die App sofort.
    var flushBeforeQuit: (@MainActor () async -> Void)?

    /// Verhindert eine zweite Runde, falls AppKit erneut fragt, während der
    /// Flush noch läuft (z. B. ⌘Q doppelt gedrückt) — sonst hinge das Beenden
    /// an einem `reply`, das nie kommt.
    private var flushInFlight = false

    /// Fenster zu ≠ App beenden. Explizit gesetzt, weil dieser Delegate den
    /// von SwiftUI selbst installierten ERSETZT — und weil genau dieses
    /// Verhalten schon einmal ein App-Review-Befund war (Guideline 4: „no menu
    /// item to re-open it"). Der Weg zurück ist Fenster ▸ Schreibfenster (⌘0);
    /// beendete die App beim Schliessen, wäre der Eintrag sinnlos.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let flush = flushBeforeQuit, !flushInFlight else { return .terminateNow }
        flushInFlight = true
        Task { @MainActor in
            await flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
