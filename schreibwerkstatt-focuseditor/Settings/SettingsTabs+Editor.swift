//
//  SettingsTabs+Editor.swift
//  schreibwerkstatt-focuseditor
//
//  Editor-nahe Einstellungen-Tabs: „Typografie" (Schriftgrösse/-art, Zeilenhöhe,
//  Spaltenbreite, Papier-Ton, Fokus-Abdunklung) und „Schreiben" (Statistik,
//  Synonyme, Seitenziel, Auto-Save). Gehostet von `SettingsView`. Die Werte
//  fliessen über die Bridge als CSS bzw. an `mountStandaloneFocus` — kein Fork.
//

import SwiftUI

// MARK: - Typografie (Schriftgrösse, Zeilenhöhe, Spaltenbreite, Familie, Papier)

struct TypographySettingsTab: View {
    @EnvironmentObject private var typography: TypographyController
    @State private var showResetAlert = false

    var body: some View {
        Form {
            Section(t("settings.typo.fontSection")) {
                Picker(t("settings.typo.fontFamily"), selection: $typography.fontFamily) {
                    ForEach(EditorFontFamily.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }

                LabeledContent(t("settings.typo.fontSize")) {
                    HStack {
                        Slider(value: $typography.fontSize,
                               in: TypographyController.fontSizeRange, step: 1)
                        Text("\(Int(typography.fontSize.rounded())) px")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                LabeledContent(t("settings.typo.lineHeight")) {
                    HStack {
                        Slider(value: $typography.lineHeight,
                               in: TypographyController.lineHeightRange, step: 0.05)
                        Text(String(format: "%.2f", typography.lineHeight))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            Section(t("settings.typo.layoutSection")) {
                Toggle(t("settings.typo.limitMeasure"), isOn: measureEnabled)
                if typography.measure > 0 {
                    LabeledContent(t("settings.typo.width")) {
                        HStack {
                            Slider(value: $typography.measure,
                                   in: TypographyController.measureRange, step: 1)
                            Text("\(Int(typography.measure.rounded())) ch")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Text(t("settings.typo.measureHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.typo.paperSection")) {
                Picker(t("settings.typo.background"), selection: $typography.paperTone) {
                    ForEach(PaperTone.allCases) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
                Text(t("settings.typo.paperHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.typo.dimSection")) {
                Toggle(t("settings.typo.dimCustom"), isOn: $typography.focusDimEnabled)
                if typography.focusDimEnabled {
                    LabeledContent(t("settings.typo.dimAmount")) {
                        HStack {
                            // Slider von „dezent" (hohe Opazität) nach „stark"
                            // (niedrige Opazität) — invertiert, damit rechts = stärker.
                            Slider(value: dimStrength, in: 0...1)
                            Text(String(format: "%.0f %%", (1 - typography.focusDimOpacity) * 100))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Text(t("settings.typo.dimHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Spacer()
                    // Bestätigung wie bei den anderen Einklick-Destruktiven (Abmelden,
                    // Cache leeren, Server-Wechsel) — ein versehentlicher Klick würde
                    // sonst alle Typografie-Einstellungen auf einmal verwerfen.
                    Button(t("settings.typo.reset")) { showResetAlert = true }
                }
            }
        }
        .formStyle(.grouped)
        .alert(t("settings.typo.resetAlertTitle"), isPresented: $showResetAlert) {
            Button(t("general.cancel"), role: .cancel) {}
            Button(t("settings.typo.resetConfirm"), role: .destructive) {
                typography.resetToDefaults()
            }
        } message: {
            Text(t("settings.typo.resetAlertMessage"))
        }
    }

    /// Slider 0…1 (links dezent, rechts stark) ⇄ Opazität (0.6…0.05).
    private var dimStrength: Binding<Double> {
        let range = TypographyController.focusDimRange
        return Binding(
            get: { (range.upperBound - typography.focusDimOpacity) / (range.upperBound - range.lowerBound) },
            set: { typography.focusDimOpacity = range.upperBound - $0 * (range.upperBound - range.lowerBound) }
        )
    }

    /// Toggle koppelt „begrenzen" an measure==0 (aus) bzw. den letzten Wert.
    private var measureEnabled: Binding<Bool> {
        Binding(
            get: { typography.measure > 0 },
            set: { typography.measure = $0 ? 64 : 0 }
        )
    }
}

// MARK: - Schreiben (Statistik + Seitenziel)

struct WritingSettingsTab: View {
    @EnvironmentObject private var stats: WritingStatsStore
    @EnvironmentObject private var core: AppCore
    /// Auto-Save-Debounce in ms (an mountStandaloneFocus durchgereicht).
    @AppStorage(EditorBehaviorPrefs.autosaveKey) private var autosaveMs = 1500.0
    /// Synonym-Hilfe (Cmd+Shift+S) gerätelokal an/aus.
    @AppStorage(SynonymPrefs.enabledKey) private var synonymsEnabled = true
    /// Zählwert an der Zeile im Seiten-Picker (⌘O).
    @AppStorage(PagePickerMetric.defaultsKey) private var pickerMetric = PagePickerMetric.chars

    var body: some View {
        Form {
            Section(t("settings.writing.statsSection")) {
                Toggle(t("settings.writing.showStats"), isOn: $stats.showStats)
                Picker(t("settings.writing.pickerMetric"), selection: $pickerMetric) {
                    ForEach(PagePickerMetric.allCases) { metric in
                        Text(t(metric.labelKey)).tag(metric)
                    }
                }
                Text(t("settings.writing.pickerMetricHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.writing.synonymSection")) {
                Toggle(t("settings.writing.synonymToggle"), isOn: $synonymsEnabled)
                    .onChange(of: synonymsEnabled) {
                        Task { await core.bridge.pushSynonymsEnabled() }
                    }
                Text(t("settings.writing.synonymHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.writing.goalSection")) {
                Toggle(t("settings.writing.goalToggle"), isOn: goalEnabled)
                if stats.pageGoalWords > 0 {
                    Stepper(value: $stats.pageGoalWords, in: 50...5000, step: 50) {
                        LabeledContent(t("settings.writing.goal"),
                                       value: t("settings.writing.goalWords", ["n": "\(stats.pageGoalWords)"]))
                    }
                }
                Text(t("settings.writing.goalHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.writing.autosaveSection")) {
                LabeledContent(t("settings.writing.autosaveDelay")) {
                    HStack {
                        Slider(value: $autosaveMs,
                               in: EditorBehaviorPrefs.autosaveRange, step: 250)
                        Text(String(format: "%.2g s", autosaveMs / 1000))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Text(t("settings.writing.autosaveHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Toggle koppelt „Ziel an" an pageGoalWords==0 (aus) bzw. einen Default.
    private var goalEnabled: Binding<Bool> {
        Binding(
            get: { stats.pageGoalWords > 0 },
            set: { stats.pageGoalWords = $0 ? 500 : 0 }
        )
    }
}
