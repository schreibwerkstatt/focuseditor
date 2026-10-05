//
//  ContentView.swift
//  schreibwerkstatt-focuseditor
//
//  Created by David Berger on 14.06.2026.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var auth: AuthStore
    /// Beobachtet die App-Sprache: ein Sprachwechsel rendert den ganzen Baum neu
    /// (frische `t()`-Werte), ohne den Editor-WebView neu zu laden.
    @EnvironmentObject private var loc: LocalizationController

    var body: some View {
        Group {
            switch auth.state {
            case .unknown:
                LoadingView()
            case .validating:
                // Beim Erst-Login zeigt LoginView selbst einen Spinner;
                // hier nur der Bootstrap-Fall (Token wird geprüft).
                auth.hasStoredToken ? AnyView(LoadingView()) : AnyView(LoginView())
            case .signedOut:
                LoginView()
            case .signedIn:
                EditorHostView()
            }
        }
        // Sanfter Crossfade zwischen den Grundzuständen (v. a. Login/Laden →
        // Editor beim Anmelden) statt hartem Umschalten.
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: auth.state)
    }
}

/// Schlichter Lade-Zustand während Bootstrap/Token-Prüfung.
private struct LoadingView: View {
    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(t("content.a11y.loading"))
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

/// Editor-Host nach erfolgreichem Login: hostet die WKWebView (Focus-Editor
/// bzw. Bridge-Harness) full-bleed auf der Brand-Fläche. Der lokale Speicher
/// wird hier instanziiert und in die Bridge gereicht — eine Instanz pro Fenster.
/// Abmelden liegt in der Toolbar, damit das Schreiben ablenkungsfrei bleibt.
private struct EditorHostView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var core: AppCore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var windowChrome: WindowChromeController
    @EnvironmentObject private var editorBundle: EditorBundleStore
    /// Geteilter UI-Zustand mit der (im Titelleisten-Accessory gehosteten)
    /// Toolbar: Seiten-Picker-Sichtbarkeit + zu prüfender Konflikt.
    @EnvironmentObject private var toolbarUI: ToolbarUIState
    /// Serverseitiges Seiten-Lektorat — treibt das Ergebnis-Banner (der Start
    /// liegt in der Toolbar).
    @EnvironmentObject private var lektorat: LektoratJobStore
    /// Buch-Export (Ablage ▸ „Buch exportieren …") — treibt das Ergebnis-Banner.
    @EnvironmentObject private var bookExport: BookExportController
    /// Seiten anlegen/umbenennen/löschen — treibt die drei kleinen Dialoge.
    @EnvironmentObject private var pageAdmin: PageAdminController
    /// Frühere Fassungen der offenen Seite — nur zum Zurücksetzen beim Schliessen
    /// des Sheets (Laden/Netz macht der Store selbst).
    @EnvironmentObject private var revisions: PageRevisionStore

    /// Die Banner über der Schreibfläche, von oben nach unten. Sie werden in
    /// EINEM VStack gestapelt — dadurch gibt es weder eine Offset-Rechnung noch
    /// eine angenommene Bannerhöhe mehr (vorher schob sich jeder Banner per
    /// `.padding(.top, n * 64)` unter seine Vorgänger; ein zweizeiliger Text
    /// hätte die 64 gesprengt und die Banner zum Überlappen gebracht).
    ///
    /// Rangfolge: der Save-Fehler wiegt am schwersten (Text NICHT gesichert),
    /// dann das Lektorats-Ergebnis, dann der Widerrufen-Hinweis, zuletzt die
    /// Export-Meldung (rein informativ).
    private enum Banner {
        case saveError, lektorat, history, export
    }

    private func isVisible(_ banner: Banner) -> Bool {
        switch banner {
        case .saveError: return library.saveError != nil
        case .lektorat:
            switch lektorat.phase {
            case .done, .failed: return true
            case .idle, .preparing, .running: return false
            }
        case .history: return library.historyNotice != nil
        case .export:
            switch bookExport.phase {
            case .done, .failed: return true
            case .idle, .exporting: return false
            }
        }
    }

    private var isLektoratBannerVisible: Bool { isVisible(.lektorat) }

    /// Der Bannerstapel in der Rangfolge oben. Jeder Eintrag rendert nur, wenn
    /// er sichtbar ist; die Lücken schliesst der VStack selbst.
    @ViewBuilder
    private var bannerStack: some View {
        VStack(spacing: 8) {
            if let saveError = library.saveError {
                SaveErrorBanner(message: saveError) { library.dismissSaveError() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if isVisible(.lektorat) {
                LektoratResultBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let notice = library.historyNotice {
                HistoryNoticeBanner(notice: notice) { library.dismissHistoryNotice() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if isVisible(.export) {
                BookExportBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var body: some View {
        Group {
            switch editorBundle.state {
            case .ready:
                editorReady
            case .failed(let message):
                BundleUnavailableView(message: message) {
                    Task { await editorBundle.refresh(silent: false) }
                }
            case .idle, .refreshing:
                BundleLoadingView()
            }
        }
        .animation(.easeOut(duration: 0.12), value: toolbarUI.pickerOpen)
        .animation(.easeOut(duration: 0.18), value: library.openPageId)
        .animation(.easeOut(duration: 0.12), value: library.isSwitchingBook)
        .task { await editorBundle.ensureReady() }
        .task { await library.loadBooks() }
        // Buchwechsel: die LibraryStore schliesst die offene Seite und signalisiert
        // hier, den Seiten-Picker zu öffnen (Seite des neuen Buchs wählen).
        .onChange(of: library.pickerOpenRequest) { _, _ in
            toolbarUI.pickerOpen = true
        }
        // Beginnt ein Buchwechsel, den (evtl. offenen) Picker sofort schliessen —
        // der Lade-Donut übernimmt, bis die Seiten des neuen Buchs geladen sind.
        .onChange(of: library.isSwitchingBook) { _, switching in
            if switching { toolbarUI.pickerOpen = false }
        }
    }

    /// Editor im Ready-Zustand. Die Toolbar lebt NICHT mehr hier im Content,
    /// sondern als natives Titelleisten-Accessory (s. `WindowChromeController`) —
    /// dadurch ist sie auch im macOS-Vollbild klickbar (früher verschluckte die
    /// auto-ausblendende System-Titelleiste die Klicks auf die Content-Leiste).
    /// Beim Erscheinen/Verschwinden wird das Accessory ein-/ausgeblendet, damit
    /// es auf Login-/Ladebildschirmen nicht als leerer Streifen stehen bleibt.
    @ViewBuilder
    private var editorReady: some View {
        ZStack(alignment: .top) {
            // App-weiter, geteilter Store — dieselbe Instanz, die die SyncEngine bedient.
            FocusWebView(bridge: core.bridge, webRoot: editorBundle.webRoot)
                .background(BrandColor.bg)
                .frame(minWidth: 640, minHeight: 480)

            // Ruhiger Leerzustand: keine Seite offen und kein Picker — statt
            // der schwarzen WebView-Fläche eine zentrierte Karte mit Kontext
            // (Buch) und dem klaren nächsten Schritt (Seite öffnen / zuletzt
            // fortsetzen). Deckt die WebView voll ab, damit nichts durchscheint.
            if library.openPageId == nil && !toolbarUI.pickerOpen {
                // „Geladen, aber keine Bücher zugeteilt" klar vom generischen
                // Leerzustand trennen — sonst führte „Seite öffnen" nur in einen
                // leeren Picker, ohne den wahren Grund zu nennen.
                if library.booksLoaded && library.books.isEmpty {
                    NoBooksView(reload: { Task { await library.loadBooks() } })
                        .transition(.opacity)
                } else {
                    EmptyEditorView(openPicker: { toolbarUI.pickerOpen = true })
                        .transition(.opacity)
                }
            }

            if toolbarUI.pickerOpen {
                PagePickerOverlay(isOpen: $toolbarUI.pickerOpen)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            // Meldungen über der Schreibfläche (Save-Fehler, Lektorat, Widerrufen,
            // Export) — als Stapel, damit mehrere gleichzeitig lesbar bleiben.
            bannerStack

            // Buchwechsel: zentrierter Lade-Donut über der leeren WebView, bis
            // die Seiten des neuen Buchs geladen sind und der Picker wieder öffnet.
            if library.isSwitchingBook {
                BookSwitchLoadingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: library.saveError)
        .animation(.easeOut(duration: 0.18), value: library.booksLoaded)
        .animation(.easeOut(duration: 0.18), value: isLektoratBannerVisible)
        .animation(.easeOut(duration: 0.18), value: library.historyNotice)
        .animation(.easeOut(duration: 0.18), value: isVisible(.export))
        // Toolbar-Accessory nur zeigen, solange der Editor sichtbar ist (sonst
        // stünde im Login-/Ladezustand ein leerer Streifen in der Titelleiste).
        .onAppear { windowChrome.setToolbarVisible(true) }
        .onDisappear { windowChrome.setToolbarVisible(false) }
        // Konflikt-Auflösung (Nebeneinander-Diff): aus dem Toolbar-Konfliktmenü
        // beschworen. `item:` bindet an die geprüfte Seite → ein Sheet je Konflikt.
        .sheet(item: $toolbarUI.inspectingConflict) { conflict in
            ConflictResolutionView(conflict: conflict)
        }
        // Frühere Fassungen der offenen Seite (⌘⇧R). Beim Öffnen laden, beim
        // Schliessen zurücksetzen — die Liste soll nie veraltet wieder aufgehen.
        .sheet(isPresented: $toolbarUI.revisionsOpen) {
            RevisionsView(onRestored: reloadAfterRestore) {
                toolbarUI.revisionsOpen = false
            }
            .onDisappear { revisions.reset() }
        }
        .sheet(isPresented: $toolbarUI.newPageOpen) {
            NewPageSheet { toolbarUI.newPageOpen = false }
        }
        .sheet(item: $toolbarUI.renamingPage) { page in
            RenamePageSheet(page: page) { toolbarUI.renamingPage = nil }
        }
        // Löschen bewusst als Alert, nicht als Sheet: es ist eine Ja/Nein-Frage
        // mit Folgen, kein Formular.
        .alert(t("pageadmin.delete.title"),
               isPresented: Binding(get: { toolbarUI.deletingPage != nil },
                                    set: { if !$0 { toolbarUI.deletingPage = nil } })) {
            Button(t("general.cancel"), role: .cancel) { toolbarUI.deletingPage = nil }
            Button(t("pageadmin.delete.confirm"), role: .destructive) {
                if let page = toolbarUI.deletingPage {
                    Task { await pageAdmin.deletePage(id: page.id) }
                }
                toolbarUI.deletingPage = nil
            }
        } message: {
            Text(t("pageadmin.delete.message",
                   ["name": toolbarUI.deletingPage?.name ?? ""]))
        }
    }

    /// Nach einer wiederhergestellten Revision: den frischen Server-Stand
    /// VERBINDLICH übernehmen (der Restore schrieb serverseitig eine neue
    /// Fassung). Ein gewöhnlicher Pull übersprünge eine dirty Seite oder eine
    /// mit Outbox-Eintrag — und der lokale Stand drehte die Wiederherstellung
    /// beim nächsten Push wieder zurück.
    private func reloadAfterRestore() {
        guard let pageId = library.openPageId else { return }
        Task { await sync.adoptServerStateAfterRestore(pageId: String(pageId)) }
    }
}

/// Ruhiger Leerzustand, wenn keine Seite geöffnet ist (z. B. nach „Seite
/// schliessen" und Abbruch des Pickers). Bewusst still und markengerecht — kein
/// Dashboard: nur Buchkontext und der nächste Schritt. Zwei Wege zurück ins
/// Schreiben: die zuletzt bearbeitete Seite fortsetzen (primär, wenn bekannt)
/// oder den Seiten-Picker öffnen (⌘O greift parallel über die Toolbar).
private struct EmptyEditorView: View {
    @EnvironmentObject private var library: LibraryStore
    let openPicker: () -> Void

    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "book.closed")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(BrandColor.faint)
                    .accessibilityHidden(true)   // dekorativ; der Text sagt es

                VStack(spacing: 5) {
                    if let book = library.activeBookName {
                        Text(book)
                            .font(BrandFont.serif(17))
                            .foregroundStyle(BrandColor.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(t("empty.noPageOpen"))
                        .font(BrandFont.sans(13))
                        .foregroundStyle(BrandColor.faint)
                }
                // Buchname + Zustand als EIN Satz vorlesen statt als Fragmente.
                .accessibilityElement(children: .combine)

                VStack(spacing: 10) {
                    if let last = library.lastOpenPageRow {
                        EmptyStateButton(title: t("empty.continueLast", ["name": last.name]),
                                         prominent: true) {
                            library.openPage(last)
                        }
                    }
                    EmptyStateButton(title: t("empty.openPage"),
                                     shortcut: "⌘O",
                                     prominent: library.lastOpenPageRow == nil,
                                     action: openPicker)
                }
                .frame(maxWidth: 320)
            }
            .padding(40)
        }
        // Leerzustand deckt die WebView ab: deren I-Beam-(Text-)Cursor darf nicht
        // durchscheinen → über der ganzen Fläche den Pfeil erzwingen. View-gebunden
        // (wie Toolbar/Picker), zuverlässiger als das transiente `NSCursor.set()`.
        // Die Knöpfe übersteuern lokal mit `.pointerStyle(.link)`.
        .pointerDefault()
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Bücherliste erfolgreich geladen, aber leer: dem Account ist (noch) kein Buch
/// zugeteilt. Klar benannt statt der generischen „keine Seite offen"-Fläche, die
/// nur in einen leeren Picker führte. Kein Anlege-Pfad im Client (reine
/// Schreib-Hülle) → Hinweis auf die Web-Plattform + ein „erneut laden"-Knopf
/// (falls gerade ein Buch in der Web-App entstanden ist).
private struct NoBooksView: View {
    let reload: () -> Void

    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(BrandColor.faint)
                    .accessibilityHidden(true)
                VStack(spacing: 5) {
                    Text(t("empty.noBooksTitle"))
                        .font(BrandFont.serif(17))
                        .foregroundStyle(BrandColor.muted)
                    Text(t("empty.noBooksHint"))
                        .font(BrandFont.sans(13))
                        .foregroundStyle(BrandColor.faint)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                EmptyStateButton(title: t("content.retry"), prominent: true, action: reload)
                    .frame(maxWidth: 240)
            }
            .padding(40)
        }
        // Wie der Leerzustand: I-Beam der WebView nicht durchscheinen lassen.
        .pointerDefault()
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Warn-Banner über dem Editor, wenn ein lokaler Save fehlschlug (potenzieller
/// Datenverlust). Bewusst auffällig (Warnfarbe) statt einer stillen Log-Zeile —
/// der Nutzer muss wissen, dass sein Tippstand NICHT gesichert wurde. Schliessen
/// per Knopf; ein nächster erfolgreicher Save löst ihn ohnehin automatisch.
private struct SaveErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        NoticeBanner(
            tone: .critical,
            icon: "exclamationmark.triangle.fill",
            title: t("save.failedTitle"),
            message: message,
            dismissLabel: t("save.dismiss"),
            dismiss: dismiss)
    }
}

/// Knopf des Leerzustands: ein prominenter Akzent-Knopf (primärer Weg zurück
/// ins Schreiben) oder eine zurückgenommene Variante; optional mit Kürzel-Chip.
private struct EmptyStateButton: View {
    let title: String
    var shortcut: String? = nil
    let prominent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(BrandFont.sans(13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let shortcut {
                    Text(shortcut)
                        .font(BrandFont.sans(11))
                        .foregroundStyle(prominent ? BrandColor.bg.opacity(0.7) : BrandColor.faint)
                }
            }
            .foregroundStyle(prominent ? BrandColor.bg : BrandColor.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(prominent ? .clear : BrandColor.faint.opacity(0.8), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Knopf ist ein klickbares Ziel → Zeigehand statt des durchblutenden
        // I-Beam-Cursors der darunterliegenden WebView. View-gebunden über
        // `.pointerStyle` statt `NSCursor.push()/pop()`: der Stack lief sonst aus
        // dem Gleichgewicht, wenn der Klick den Knopf entfernt (Seite öffnet),
        // bevor `onHover(false)` feuert → Zeigehand blieb über der Schreibfläche
        // hängen. Deklarativ kann das nicht passieren.
        .pointerLink()
    }

    private var background: Color {
        if prominent {
            return hovering ? BrandColor.accent.opacity(0.85) : BrandColor.accent
        }
        return hovering ? BrandColor.faint.opacity(0.25) : .clear
    }
}

/// Erst-Download/Refresh des Editor-Bundles ohne vorhandenen Cache.
private struct BundleLoadingView: View {
    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                    .accessibilityHidden(true)   // der Text daneben trägt die Aussage
                Text(t("content.loadingEditor"))
                    .font(BrandFont.sans(13))
                    .foregroundStyle(BrandColor.muted)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Buchwechsel-Übergang: deckt die (geleerte) WebView ab und zeigt einen
/// zentrierten Lade-Donut, bis die Seiten des neuen Buchs geladen sind.
private struct BookSwitchLoadingView: View {
    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                    .accessibilityHidden(true)
                Text(t("library.switchingBook"))
                    .font(BrandFont.sans(13))
                    .foregroundStyle(BrandColor.muted)
            }
        }
        // Wie der Leerzustand: I-Beam der WebView nicht durchscheinen lassen.
        .pointerDefault()
    }
}

/// Kein Cache UND Download fehlgeschlagen (typisch: erster Start offline).
private struct BundleUnavailableView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(BrandColor.muted)
                    .accessibilityHidden(true)
                Text(t("content.editorUnavailableTitle"))
                    .font(BrandFont.serif(18))
                Text(message)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button(t("content.retry"), action: retry)
            }
            .padding(40)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthStore())
        .environmentObject(LocalizationController())
}
