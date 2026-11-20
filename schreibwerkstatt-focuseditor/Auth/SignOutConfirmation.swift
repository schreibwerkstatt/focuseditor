//
//  SignOutConfirmation.swift
//  schreibwerkstatt-focuseditor
//
//  Abmelden mit Rückfrage — für die Wege ausserhalb der Einstellungen
//  (App-Menü, Überlauf der Toolbar). Die Einstellungen fragen schon nach;
//  ohne diese Hülle meldete ein Fehlklick im Menü sofort ab, und der
//  Wiedereinstieg verlangt ein neues Gerätetoken per Copy-Paste.
//
//  Als NSAlert statt SwiftUI-`.alert`: das App-Menü hat keine eigene View,
//  an der ein Alert hängen könnte, und der Weg muss auch funktionieren, wenn
//  der Editor gerade nicht steht (Bundle-Fehler, Ladezustand).
//

import AppKit

@MainActor
enum SignOutConfirmation {
    /// Fragt nach und meldet bei Bestätigung ab. Als Sheet am Hauptfenster,
    /// sonst als eigenständiges Fenster.
    static func run(_ auth: AuthStore) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("settings.account.signOutAlertTitle")
        alert.informativeText = t("settings.account.signOutAlertMessage")
        alert.addButton(withTitle: t("general.signOut"))
        alert.addButton(withTitle: t("general.cancel"))
        alert.buttons.first?.hasDestructiveAction = true

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { auth.signOut() }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
