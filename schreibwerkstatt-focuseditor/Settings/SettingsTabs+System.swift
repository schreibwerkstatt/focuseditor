//
//  SettingsTabs+System.swift
//  schreibwerkstatt-focuseditor
//
//  System-/Konto-nahe Einstellungen-Tabs: „Sync" (Poll-Kadenz/Pause/Status),
//  „Rechtschreibung" (lokale LanguageTool-Overrides) und „Konto" (Abmelden +
//  App-/Editor-Bundle-Wartung + Datenschutz). Gehostet von `SettingsView`.
//

import SwiftUI

// MARK: - Sync (Poll-Kadenz, Pause, Status)

struct SyncSettingsTab: View {
    @EnvironmentObject private var sync: SyncEngine

    var body: some View {
        Form {
            Section(t("settings.sync.updateSection")) {
                Picker(t("settings.sync.pollCadence"), selection: $sync.pollMode) {
                    ForEach(SyncPollMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.inline)

                Text(t("settings.sync.cadenceHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.sync.pauseSection")) {
                Toggle(t("settings.sync.pauseToggle"), isOn: $sync.isPaused)
                Text(t("settings.sync.pauseHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.sync.statusSection")) {
                LabeledContent(t("settings.sync.state"), value: statusText)
                LabeledContent(t("settings.sync.lastSynced"), value: lastSyncedText)
                if sync.pendingCount > 0 {
                    LabeledContent(t("settings.sync.pending"),
                                   value: tn(sync.pendingCount, "settings.sync.pendingValue"))
                }
                if !sync.conflicts.isEmpty {
                    LabeledContent(t("settings.sync.conflicts"), value: "\(sync.conflicts.count)")
                        .foregroundStyle(BrandColor.warning)
                }
                HStack {
                    Spacer()
                    Button(t("settings.sync.syncNow")) { sync.syncManually() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch sync.status {
        case .idle:    return sync.isPaused ? t("sync.state.paused") : t("sync.state.ready")
        case .syncing: return t("sync.state.syncing")
        case .offline: return t("sync.state.offline")
        case .serverUnreachable: return t("sync.state.serverUnreachable")
        }
    }

    private var lastSyncedText: String {
        guard let last = sync.lastSyncedAt else { return t("sync.lastSynced.never") }
        return RelativeTime.string(for: last)
    }
}

// MARK: - Rechtschreibung (lokale LanguageTool-Overrides)

struct SpellcheckSettingsTab: View {
    @AppStorage(SpellcheckPrefs.enabledKey) private var localEnabled = true
    @AppStorage(SpellcheckPrefs.languageKey) private var languageRaw = "auto"

    var body: some View {
        Form {
            Section(t("settings.spell.section")) {
                Toggle(t("settings.spell.deviceToggle"), isOn: $localEnabled)
                Text(t("settings.spell.deviceHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.spell.languageSection")) {
                Picker(t("settings.spell.checkLanguage"), selection: $languageRaw) {
                    ForEach(SpellcheckLanguage.allCases) { lang in
                        Text(lang.label).tag(lang.rawValue)
                    }
                }
                .disabled(!localEnabled)
                Text(t("settings.spell.languageHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(t("settings.spell.serverNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Konto (Abmelden + Editor-Bundle-Wartung)

struct AccountSettingsTab: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var editorBundle: EditorBundleStore
    @EnvironmentObject private var core: AppCore
    // Nur im DMG-Target — im App-Store-Build gibt es keinen Sparkle-Updater.
    #if SPARKLE
    @EnvironmentObject private var updater: UpdaterController
    #endif
    @Environment(\.openURL) private var openURL
    @State private var showLogoutAlert = false
    @State private var showClearCacheAlert = false
    @State private var showResetMirrorAlert = false

    var body: some View {
        Form {
            Section(t("settings.account.signinSection")) {
                LabeledContent(t("settings.account.server"), value: ServerConfig.baseURLString)
                LabeledContent(t("settings.account.status"),
                               value: auth.state == .signedIn ? t("settings.account.signedIn") : t("settings.account.signedOut"))
                HStack {
                    Spacer()
                    Button(t("general.signOut"), role: .destructive) { showLogoutAlert = true }
                        .disabled(auth.state != .signedIn)
                }
                Text(t("settings.account.signOutHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // App-Update — betrifft die native App selbst, getrennt vom
            // Editor-Bundle (Content) weiter unten. Im DMG-Target läuft das über
            // Sparkle (Hintergrund-Checks automatisch, Knopf für sofortige
            // Prüfung); im App-Store-Build bleibt nur die Versionsanzeige, weil
            // dort der Store aktualisiert.
            Section(t("settings.account.appUpdateSection")) {
                LabeledContent(t("settings.account.appVersion"), value: appVersion)
                #if SPARKLE
                HStack {
                    Spacer()
                    Button(t("settings.account.checkAppUpdate")) {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
                Text(t("settings.account.appUpdateHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                Text(t("settings.account.appUpdateHintStore"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }

            Section(t("settings.account.editorVersionSection")) {
                LabeledContent(t("settings.account.sourceCommit"), value: commitShort)
                HStack {
                    if editorBundle.isCheckingUpdate { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(t("settings.account.checkUpdate")) {
                        Task { await editorBundle.checkForUpdate() }
                    }
                    .disabled(editorBundle.isCheckingUpdate)
                }
                Text(t("settings.account.updateHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.account.maintenanceSection")) {
                HStack {
                    Spacer()
                    Button(t("settings.account.clearCache")) { showClearCacheAlert = true }
                }
                Text(t("settings.account.clearCacheHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack {
                    Spacer()
                    Button(t("settings.account.resetMirror"), role: .destructive) { showResetMirrorAlert = true }
                }
                Text(t("settings.account.resetMirrorHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Diagnose-Bericht für Support-Anfragen (Zustand + eigene
            // Log-Zeilen, ohne Token und ohne Manuskript-Text).
            DiagnosticsSection()

            // Datenschutz/Datenhaltung — in-app dokumentiert (keine externe URL).
            // Teilt den Wortlaut mit dem Login-Onboarding (`login.privacyBody`),
            // damit die Aussage an beiden Stellen identisch und wartbar bleibt.
            Section(t("settings.account.privacySection")) {
                Text(t("login.privacyBody"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(t("login.privacyShowFull")) {
                        openURL(ServerConfig.pageURL(onServer: ServerConfig.baseURLString,
                                                     path: "datenschutz"))
                    }
                }
            }

            // Konto-Löschung in der App (App-Store-Guideline 5.1.1(v)).
            // Bewusst ganz unten und in einer eigenen Datei — irreversibel.
            AccountDeletionSection()
        }
        .formStyle(.grouped)
        .alert(t("settings.account.signOutAlertTitle"), isPresented: $showLogoutAlert) {
            Button(t("general.cancel"), role: .cancel) {}
            Button(t("general.signOut"), role: .destructive) { auth.signOut() }
        } message: {
            Text(t("settings.account.signOutAlertMessage"))
        }
        .alert(t("settings.account.clearCacheAlertTitle"), isPresented: $showClearCacheAlert) {
            Button(t("general.cancel"), role: .cancel) {}
            Button(t("settings.account.clearAndReload"), role: .destructive) {
                Task { await editorBundle.clearEditorCache() }
            }
        } message: {
            Text(t("settings.account.clearCacheAlertMessage"))
        }
        .alert(t("settings.account.resetMirrorAlertTitle"), isPresented: $showResetMirrorAlert) {
            Button(t("general.cancel"), role: .cancel) {}
            Button(t("settings.account.resetMirrorConfirm"), role: .destructive) {
                Task { await core.resetLocalMirror() }
            }
        } message: {
            Text(t("settings.account.resetMirrorAlertMessage"))
        }
    }

    private var commitShort: String {
        guard let c = editorBundle.sourceCommit, !c.isEmpty, c != "unknown" else { return "—" }
        return String(c.prefix(10))
    }

    /// Sichtbare App-Version aus der Info.plist (CFBundleShortVersionString,
    /// gespeist aus MARKETING_VERSION in Version.xcconfig).
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { "v\($0)" } ?? "—"
    }
}
