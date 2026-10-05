//
//  AppCore+ServerSwitch.swift
//  schreibwerkstatt-focuseditor
//
//  Namespace-Wechsel des `AppCore`: den lokalen Spiegel, den Sync-Zustand und
//  die Buchauswahl von einem Server auf einen anderen umhängen — und der eine
//  Pfad, der lokale Inhalte VERWIRFT (nach bestätigter Konto-Löschung).
//
//  Warum getrennt von AppCore.swift: dort steht der Aufbau (wer besitzt wen,
//  welche Rückrufe hängen wo). Hier steht der Umbau im laufenden Betrieb — ein
//  eigenes Thema mit eigener Reihenfolge-Empfindlichkeit (Sync anhalten VOR dem
//  Store-Tausch, aufräumen VOR dem Abmelden). Zusammen in einer Datei las sich
//  das eine wie eine Fortsetzung des anderen.
//

import Foundation
import os

extension AppCore {

    /// Server-Wechsel (in-place): den lokalen Spiegel, den Sync-Zustand und die
    /// Buchauswahl auf den Namespace des NEUEN Servers umschalten. Ohne das pollt
    /// der Client weiter die Buch-IDs des alten Servers (→ `NO_BOOK_ACCESS`-Flut).
    /// Voraussetzung: `ServerConfig.baseURLString` zeigt bereits auf den neuen
    /// Server (der Aufrufer setzt URL + meldet ab, bevor er das hier ruft).
    ///
    /// Objekt-Identitäten bleiben erhalten (Store/Sync/Library tauschen nur ihre
    /// zugrundeliegenden Dateien) → Bridge- und Controller-Bindungen bleiben gültig.
    func switchServer() async {
        await closeOpenPageBeforeRebind()
        // Sync VOR dem Store-Tausch anhalten und einen laufenden Durchlauf
        // abwarten — sonst committet ein in-flight DB-Write evtl. noch in die
        // alte Namespace-DB (Datenverlust für den neuen Server).
        await sync.suspendForServerSwitch()
        // Schreibzeit-Puffer des alten Servers verwerfen (Buch-IDs gelten nur dort).
        writingTime.reset()
        // Laufendes/abgeschlossenes Lektorat verwerfen: Job-ID und Deep-Link
        // gelten nur am alten Server.
        lektorat.reset()
        // Verzögerten Spellcheck-Nachzieh-Versuch für den NEUEN Server
        // freigeben (Boot-Config des alten Servers könnte `enabled:false`
        // geliefert haben). Die JS-Seite bleibt idempotent (Guard
        // `if (window.__spellcheck) return`); ein Re-Mount findet nur statt,
        // wenn der neue Server enabled liefert UND noch nichts mounted ist.
        bridge.resetSpellcheckDeferred()
        await rebindStoresToCurrentServer(context: "Server-Wechsel")
    }

    /// Schaltet nur um, wenn sich der Server-Namespace seit dem letzten Binden
    /// geändert hat. Deckt den Login-Pfad ab (URL im Login-Screen editiert, dann
    /// angemeldet) und ist nach einem direkten `switchServer()` ein No-op. Der
    /// Reentrancy-Guard verhindert, dass der mehrfach feuernde Sign-in-Publisher
    /// zwei Wechsel überlappend fährt (Race auf Store/Sync-Zustand).
    func switchServerIfNeeded() async {
        guard !switchInFlight, boundSlug != ServerNamespace.currentSlug else { return }
        switchInFlight = true
        defer { switchInFlight = false }
        await switchServer()
    }

    /// Nach bestätigter Konto-Löschung am Server: alle lokalen Inhalte dieses
    /// Servers verwerfen. Bewusst NUR aus diesem Pfad heraus aufgerufen — überall
    /// sonst gilt „Datenverlust-Schutz vor allem" (Abmelden/401 behalten alles).
    ///
    /// Ablauf wie beim Server-Wechsel: Sync anhalten (kein in-flight Write in die
    /// gleich gelöschte DB), Puffer verwerfen, Dateien + Defaults löschen, danach
    /// eine frische (leere) DB am selben Pfad öffnen und Sync/Library darauf neu
    /// aufsetzen — die Objekt-Identitäten bleiben gültig (Bridge-Bindungen etc.).
    func purgeLocalDataForCurrentServer() async {
        await closeOpenPageBeforeRebind()
        await sync.suspendForServerSwitch()
        lektorat.reset()
        // Löschen und Verwerfen des Schreibzeit-Puffers ohne `await` dazwischen:
        // auf dem MainActor kann kein Heartbeat-Tick einhaken und den alten
        // `pending`-Wert nach dem Purge zurückschreiben. `reset()` zieht den
        // In-Memory-Puffer danach aus den (nun leeren) Defaults nach.
        LocalDataPurge.purgeServerNamespace()
        writingTime.reset()
        await rebindStoresToCurrentServer(context: "Konto-Löschung")
    }

    /// Der gemeinsame Schluss beider Pfade: Spiegel auf den Namespace des jetzt
    /// konfigurierten Servers öffnen, Sync und Bücherliste darauf neu aufsetzen,
    /// Bindung vermerken. Die Objekt-Identitäten bleiben dabei erhalten — nur die
    /// zugrundeliegenden Dateien wechseln —, darum überleben alle Bridge- und
    /// Controller-Verdrahtungen aus `AppCore.init`.
    ///
    /// Ein fehlgeschlagenes Öffnen wird geloggt, aber nicht geworfen: Sync und
    /// Library müssen trotzdem umgestellt werden, sonst arbeiteten sie mit den
    /// Buch-IDs des alten Servers weiter (→ `NO_BOOK_ACCESS`-Flut).
    ///
    /// Scheitert das Öffnen, hält der Store weiter die DB des ALTEN Servers. Der
    /// Sync bleibt dann angehalten (`haltAfterFailedStoreSwitch`): mit dem
    /// Sync-Zustand des neuen Servers gegen die Outbox des alten liefe sonst ein
    /// fremder Seitenstand bei gleicher Seiten-ID als Push durch. Die Bindung
    /// bleibt unvermerkt, damit der nächste Sign-in den Wechsel erneut versucht.
    private func rebindStoresToCurrentServer(context: String) async {
        do {
            try await store.switchToCurrentServer()
        } catch {
            AppLog.store.error("\(context, privacy: .public): Store nicht öffenbar — \(error.localizedDescription, privacy: .public)")
            sync.haltAfterFailedStoreSwitch()
            library.reloadForCurrentServer()
            return
        }
        sync.reloadForCurrentServer()
        library.reloadForCurrentServer()
        boundSlug = ServerNamespace.currentSlug
    }

    /// Vor jedem Umhängen des Spiegels: den offenen Draft sichern (awaitbar) und
    /// die Seite im Editor schliessen. Sonst bliebe die Seite des alten Servers
    /// in der Schreibfläche stehen, während die Toolbar schon „keine Seite"
    /// zeigt — und ihr nächster Autosave landete im Spiegel des NEUEN Servers.
    /// Der Save des Close-Handlers ist nach dem Flush ein No-op (Inhalt
    /// unverändert).
    private func closeOpenPageBeforeRebind() async {
        guard bridge.openPageId != nil else { return }
        await bridge.flushDraftSave()
        await bridge.closePage()
    }

    /// Lokalen Spiegel manuell zurücksetzen (auf Nutzerwunsch): Alle lokalen
    /// Inhalte (Seiten, Outbox, Sync-Zustand) verwerfen und frisch vom Server
    /// neu aufbauen. Nützlich bei Sync-Problemen (z. B. verwaiste Seiten, die
    /// nicht mehr pushbar sind). Bewusst NICHT automatisch — Datenverlust-Schutz
    /// gilt auch hier: Der Nutzer muss explizit bestätigen.
    ///
    /// Ablauf wie `purgeLocalDataForCurrentServer`, aber ohne Konto-Löschung.
    /// Der Sync baut den Spiegel beim nächsten Tick frisch aus dem Server auf.
    func resetLocalMirror() async {
        await closeOpenPageBeforeRebind()
        await sync.suspendForServerSwitch()
        lektorat.reset()
        writingTime.reset()
        LocalDataPurge.purgeServerNamespace()
        await rebindStoresToCurrentServer(context: "Lokaler Spiegel-Reset")
    }

}
