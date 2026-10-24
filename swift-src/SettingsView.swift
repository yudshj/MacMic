import SwiftUI
import AppKit
import Combine

public enum SettingsTab: String, CaseIterable, Identifiable {
    case display = "display"
    case general = "general"
    case about = "about"

    public var id: String { rawValue }

    public func title(using l10n: LocalizationManager) -> String {
        switch self {
        case .display: return l10n.t("tab_display")
        case .general: return l10n.t("tab_general")
        case .about: return l10n.t("tab_about")
        }
    }

    public var icon: String {
        switch self {
        case .display: return "paintpalette.fill"
        case .general: return "gearshape.fill"
        case .about: return "info.circle.fill"
        }
    }
}

public final class SettingsViewModel: ObservableObject {
    @Published public var selectedTab: SettingsTab = .display
    @Published public var launchAtLogin: Bool {
        didSet {
            LaunchAtLoginHelper.isEnabled = launchAtLogin
        }
    }
    @Published public var hideDock: Bool {
        didSet {
            UserDefaults.standard.set(hideDock, forKey: "macmic_hide_dock")
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(self.hideDock ? .accessory : .regular)
            }
        }
    }

    public init() {
        self.launchAtLogin = LaunchAtLoginHelper.isEnabled
        self.hideDock = UserDefaults.standard.bool(forKey: "macmic_hide_dock")
    }
}

/// System Settings–style row icon: white glyph on a colored rounded square.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color)
            )
    }
}

/// One row inside a grouped settings card.
struct SettingsRow<Accessory: View>: View {
    let icon: String
    let color: Color
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(systemName: icon, color: color)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }
}

public struct SettingsView: View {
    @ObservedObject var l10n = LocalizationManager.shared
    @StateObject private var vm = SettingsViewModel()
    @Environment(\.presentationMode) var presentationMode

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Text(l10n.t("settings_title"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(l10n.t("done")) {
                    presentationMode.wrappedValue.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Tab Selector
            Picker("", selection: $vm.selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title(using: l10n), systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            // Content Area
            VStack(alignment: .leading, spacing: 8) {
                switch vm.selectedTab {
                case .display:
                    sectionHeader(l10n.t("settings_display_section"))
                    displaySection
                    sectionFooter(l10n.t("settings_appearance_footer"))
                case .general:
                    sectionHeader(l10n.t("settings_general_section"))
                    generalSection
                case .about:
                    aboutSection
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(width: 360, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(l10n.currentTheme.colorScheme)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.leading, 4)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(.secondary)
            .padding(.leading, 4)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 44)
    }

    /// Read straight from Info.plist so the about panel can never drift from the bundle version.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0.1"
        guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }

    // MARK: - Display Section
    private var displaySection: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "globe", color: .blue, title: l10n.t("settings_language")) {
                Picker("", selection: $l10n.currentLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            rowDivider

            SettingsRow(icon: "circle.lefthalf.filled", color: .indigo, title: l10n.t("settings_theme")) {
                Picker("", selection: $l10n.currentTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName(using: l10n)).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .macMicCard(padding: 0)
    }

    // MARK: - General Section
    private var generalSection: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "power", color: .green, title: l10n.t("settings_launch_at_login")) {
                Toggle("", isOn: $vm.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            rowDivider

            SettingsRow(icon: "dock.rectangle", color: .gray, title: l10n.t("settings_hide_dock")) {
                Toggle("", isOn: $vm.hideDock)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .macMicCard(padding: 0)
    }

    // MARK: - About Section
    private var aboutSection: some View {
        VStack(spacing: 12) {
            // App Badge
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacMic")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(l10n.t("about_version")) \(Self.appVersion) · Apple Silicon")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            // Info Card
            VStack(spacing: 0) {
                SettingsRow(icon: "link", color: .blue, title: l10n.t("about_project_url")) {
                    Button(action: {
                        if let url = URL(string: "https://github.com/luanyufei/MacMic") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 3) {
                            Text("GitHub")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.link)
                    .focusable(false)
                    .help(l10n.t("about_open_github"))
                }

                rowDivider

                SettingsRow(icon: "person.fill", color: .orange, title: l10n.t("about_author")) {
                    Text("FEEFEENOON")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                rowDivider

                SettingsRow(icon: "envelope.fill", color: .teal, title: l10n.t("about_email")) {
                    Button(action: {
                        if let url = URL(string: "mailto:noonyjufee@gmail.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Text("noonyjufee@gmail.com")
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .focusable(false)
                    .help(l10n.t("about_send_email"))
                }
            }
            .macMicCard(padding: 0)
        }
    }
}
