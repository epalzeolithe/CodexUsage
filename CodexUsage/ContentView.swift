import SwiftUI

#if os(macOS)
import AppKit
import AuthenticationServices
import Observation
import ServiceManagement
import WebKit

private let usageOverviewURL = URL(
    string: "https://chatgpt.com/settings/usage?tab=overview"
)!

@main
struct CodexUsageMenuApp: App {
    @State private var codexMonitor = UsageMonitor()
    @State private var claudeMonitor = ClaudeUsageMonitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView(codexMonitor: codexMonitor, claudeMonitor: claudeMonitor)
        } label: {
            MenuBarUsageLabel(
                codexTitle: codexMonitor.compactMenuTitle,
                claudeTitle: claudeMonitor.compactMenuTitle,
                accessibilityTitle: "\(codexMonitor.accessibilityMenuTitle). Quota Claude restant : \(claudeMonitor.fiveHourMenuTitle) pour cent sur 5 heures, \(claudeMonitor.weeklyMenuTitle) pour cent sur 7 jours"
            )
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarUsageLabel: View {
    let codexTitle: String
    let claudeTitle: String
    let accessibilityTitle: String

    var body: some View {
        Image(nsImage: menuBarImage)
            .accessibilityLabel(accessibilityTitle)
    }

    private var menuBarImage: NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        let textWidth = max(
            NSString(string: codexTitle).size(withAttributes: attributes).width,
            NSString(string: claudeTitle).size(withAttributes: attributes).width
        )
        let imageWidth = ceil(textWidth) + 14

        let image = NSImage(
            size: NSSize(width: imageWidth, height: 22),
            flipped: false
        ) { rect in
            Self.drawClaudeIcon(in: NSRect(x: 1, y: 1, width: 9, height: 9))
            NSString(string: claudeTitle).draw(
                in: NSRect(x: 13, y: 0, width: rect.width - 13, height: 11),
                withAttributes: attributes
            )
            Self.drawCodexIcon(in: NSRect(x: 1, y: 12, width: 9, height: 9))
            NSString(string: codexTitle).draw(
                in: NSRect(x: 13, y: 11, width: rect.width - 13, height: 11),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawCodexIcon(in rect: NSRect) {
        NSColor.black.setStroke()

        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3
            let center = NSPoint(
                x: rect.midX + cos(angle) * rect.width * 0.22,
                y: rect.midY + sin(angle) * rect.height * 0.22
            )
            let loop = NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - rect.width * 0.22,
                    y: center.y - rect.height * 0.22,
                    width: rect.width * 0.44,
                    height: rect.height * 0.44
                )
            )
            loop.lineWidth = 0.85
            loop.stroke()
        }
    }

    private static func drawClaudeIcon(in rect: NSRect) {
        NSColor.black.setStroke()
        let mark = NSBezierPath()
        mark.lineWidth = 1.05
        mark.lineCapStyle = .round

        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            mark.move(
                to: NSPoint(
                    x: rect.midX + cos(angle) * rect.width * 0.12,
                    y: rect.midY + sin(angle) * rect.height * 0.12
                )
            )
            mark.line(
                to: NSPoint(
                    x: rect.midX + cos(angle) * rect.width * 0.46,
                    y: rect.midY + sin(angle) * rect.height * 0.46
                )
            )
        }

        mark.stroke()
    }
}

@MainActor
@Observable
final class UsageMonitor: NSObject, WKNavigationDelegate {
    var fiveHourUsage: Int?
    var weeklyUsage: Int?
    var status = "Connexion à ChatGPT…"
    var lastUpdated: Date?
    var launchAtLoginEnabled = false
    var launchAtLoginMessage: String?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let backgroundWindow: NSWindow
    @ObservationIgnored private let backgroundContainer: NSView
    @ObservationIgnored private let passkeyManager =
        ASAuthorizationWebBrowserPublicKeyCredentialManager()
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var hasRedirectedAfterLogin = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)

        let backgroundContainer = NSView(
            frame: NSRect(x: 0, y: 0, width: 620, height: 620)
        )
        self.backgroundContainer = backgroundContainer
        backgroundWindow = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        super.init()

        refreshLaunchAtLoginStatus()

        backgroundWindow.contentView = backgroundContainer
        backgroundWindow.alphaValue = 0.01
        backgroundWindow.ignoresMouseEvents = true
        backgroundWindow.isReleasedWhenClosed = false
        backgroundWindow.collectionBehavior = [.stationary, .transient, .ignoresCycle]

        webView.navigationDelegate = self
        hostWebViewInBackground()
        requestPasskeyAccessIfNeeded()
        webView.load(URLRequest(url: usageOverviewURL))
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    var fiveHourMenuTitle: String {
        "5h \(fiveHourUsage.map(String.init) ?? "—")%"
    }

    var weeklyMenuTitle: String {
        "7j \(weeklyUsage.map(String.init) ?? "—")%"
    }

    var compactMenuTitle: String {
        let fiveHour = fiveHourUsage.map(String.init) ?? "—"
        let weekly = weeklyUsage.map(String.init) ?? "—"
        return "\(fiveHour)·\(weekly)%"
    }

    var accessibilityMenuTitle: String {
        guard let fiveHourUsage, let weeklyUsage else {
            return "Usage Codex indisponible"
        }
        return "Usage Codex : \(fiveHourUsage) pour cent sur 5 heures, \(weeklyUsage) pour cent sur 7 jours"
    }

    func prepareWebViewForPresentation() {
        backgroundWindow.orderOut(nil)
    }

    func hostWebViewInBackground() {
        webView.frame = backgroundContainer.bounds
        webView.autoresizingMask = [.width, .height]
        backgroundContainer.addSubview(webView)
        backgroundWindow.order(.below, relativeTo: 0)
    }

    func refresh() {
        guard let url = webView.url, isAuthenticatedChatGPTPage(url) else {
            status = "Connectez-vous à ChatGPT ci-dessous."
            return
        }

        status = "Actualisation…"
        if isUsageURL(url) {
            webView.reload()
        } else {
            webView.load(URLRequest(url: usageOverviewURL))
        }
    }

    func openInBrowser() {
        NSWorkspace.shared.open(usageOverviewURL)
    }

    func refreshLaunchAtLoginStatus() {
        let serviceStatus = SMAppService.mainApp.status
        launchAtLoginEnabled = serviceStatus == .enabled || serviceStatus == .requiresApproval
        launchAtLoginMessage = serviceStatus == .requiresApproval
            ? "Autorisation requise dans Réglages Système › Général › Ouverture."
            : nil
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = "Modification impossible : \(error.localizedDescription)"
        }
    }

    func requestPasskeyAccess() {
        passkeyManager.requestAuthorizationForPublicKeyCredentials { [weak self] state in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.updatePasskeyStatus(state)
            }
        }
    }

    private func requestPasskeyAccessIfNeeded() {
        let state = passkeyManager.authorizationStateForPlatformCredentials
        if state == .notDetermined {
            requestPasskeyAccess()
        } else {
            updatePasskeyStatus(state)
        }
    }

    private func updatePasskeyStatus(
        _ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) {
        switch state {
        case .authorized:
            if fiveHourUsage == nil {
                status = "Accès au trousseau autorisé. Connectez-vous ci-dessous."
            }
        case .denied:
            status = "Autorisez les clés d’accès dans Réglages Système › Confidentialité et sécurité."
        case .notDetermined:
            status = "Autorisation d’accès au trousseau requise."
        @unknown default:
            status = "État d’accès au trousseau inconnu."
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else {
            return
        }

        if isUsageURL(url) {
            Task {
                await extractUsage()
            }
            return
        }

        if isAuthenticatedChatGPTPage(url), !hasRedirectedAfterLogin {
            hasRedirectedAfterLogin = true
            status = "Connexion réussie. Ouverture de la page d’usage…"
            webView.load(URLRequest(url: usageOverviewURL))
        } else {
            status = "Connectez-vous à ChatGPT ci-dessous."
        }
    }

    private func isUsageURL(_ url: URL) -> Bool {
        guard isChatGPTHost(url.host) else {
            return false
        }

        return url.path.hasPrefix("/settings/usage") ||
            url.path.hasPrefix("/codex/cloud/settings/analytics")
    }

    private func isAuthenticatedChatGPTPage(_ url: URL) -> Bool {
        guard isChatGPTHost(url.host) else {
            return false
        }

        let path = url.path.lowercased()
        return !path.hasPrefix("/auth") &&
            !path.hasPrefix("/login") &&
            !path.hasPrefix("/signup")
    }

    private func isChatGPTHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        return host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    }

    private func extractUsage() async {
        status = "Lecture des limites…"

        for attempt in 1...15 {
            do {
                let result = try await webView.evaluateJavaScript(
                    Self.extractionScript,
                    in: nil,
                    contentWorld: .page
                )

                if
                    let values = result as? [String: Any],
                    let fiveHour = values["fiveHour"] as? NSNumber,
                    let weekly = values["weekly"] as? NSNumber
                {
                    fiveHourUsage = max(0, min(100, fiveHour.intValue))
                    weeklyUsage = max(0, min(100, weekly.intValue))
                    lastUpdated = .now
                    status = "À jour"
                    return
                }
            } catch {
                if attempt == 15 {
                    status = "Lecture impossible : \(error.localizedDescription)"
                    return
                }
            }

            try? await ContinuousClock().sleep(for: .seconds(1))
        }

        status = "Limites introuvables dans la page d’usage."
    }

    private static let extractionScript = """
    (() => {
        const percentagePattern = /(\\d{1,3}(?:[.,]\\d+)?)\\s*%/;
        const fiveHourPattern =
            /5\\s*(hour|hr|h|heures?)|five[ -]?hour|session limit|limite de session/i;
        const weeklyPattern =
            /weekly|week limit|7\\s*(day|days|d|jours?)|semaine|hebdomadaire|limite hebdo/i;
        const anyLimitPattern =
            /5\\s*(hour|hr|h|heures?)|five[ -]?hour|session limit|weekly|week limit|7\\s*(day|days|d|jours?)|semaine|hebdomadaire|limite hebdo/i;

        function percentage(inText) {
            const match = inText.match(percentagePattern);
            if (!match) return null;

            const value = Number(match[1].replace(",", "."));
            return Number.isFinite(value) && value >= 0 && value <= 100
                ? Math.round(value)
                : null;
        }

        function percentageAfterLabel(inText, labelPattern) {
            const scopedLines = inText
                .split(/\\n+/)
                .map(line => line.trim())
                .filter(Boolean);
            const labelIndex = scopedLines.findIndex(line => labelPattern.test(line));
            if (labelIndex < 0) return null;

            for (
                let index = labelIndex;
                index < Math.min(scopedLines.length, labelIndex + 7);
                index += 1
            ) {
                if (
                    index > labelIndex &&
                    anyLimitPattern.test(scopedLines[index])
                ) {
                    break;
                }

                const value = percentage(scopedLines[index]);
                if (value !== null) return value;
            }

            return null;
        }

        function usageFromCard(labelPattern) {
            const elements = [...document.querySelectorAll(
                "h1, h2, h3, h4, h5, h6, p, span, div, dt, dd"
            )];

            for (const element of elements) {
                const label = (element.innerText || "").trim();
                if (!label || label.length > 160 || !labelPattern.test(label)) {
                    continue;
                }

                let container = element;
                for (let depth = 0; container && depth < 6; depth += 1) {
                    const text = (container.innerText || "").trim();
                    if (text.length <= 800) {
                        const value = percentageAfterLabel(text, labelPattern);
                        if (value !== null) return value;
                    }
                    container = container.parentElement;
                }
            }

            return null;
        }

        const lines = (document.body?.innerText || "")
            .split(/\\n+/)
            .map(line => line.trim())
            .filter(Boolean);

        function usageFromLines(labelPattern) {
            const labelIndex = lines.findIndex(line => labelPattern.test(line));
            if (labelIndex < 0) return null;

            for (
                let index = labelIndex;
                index < Math.min(lines.length, labelIndex + 7);
                index += 1
            ) {
                if (index > labelIndex && anyLimitPattern.test(lines[index])) {
                    break;
                }

                const value = percentage(lines[index]);
                if (value !== null) return value;
            }

            return null;
        }

        return {
            fiveHour:
                usageFromCard(fiveHourPattern) ??
                usageFromLines(fiveHourPattern),
            weekly:
                usageFromCard(weeklyPattern) ??
                usageFromLines(weeklyPattern)
        };
    })();
    """
}

struct ContentView: View {
    enum Provider: String, CaseIterable, Identifiable {
        case codex = "Codex"
        case claude = "Claude"

        var id: Self { self }
    }

    let codexMonitor: UsageMonitor
    let claudeMonitor: ClaudeUsageMonitor
    @State private var selectedProvider = Provider.codex

    var body: some View {
        VStack(spacing: 12) {
            Picker("Service", selection: $selectedProvider) {
                ForEach(Provider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            if selectedProvider == .codex {
                ProviderUsageView(
                    fiveHourUsage: codexMonitor.fiveHourUsage,
                    weeklyUsage: codexMonitor.weeklyUsage,
                    status: codexMonitor.status,
                    lastUpdated: codexMonitor.lastUpdated
                ) {
                    AnalyticsWebView(monitor: codexMonitor)
                }
            } else {
                ProviderUsageView(
                    fiveHourUsage: claudeMonitor.fiveHourUsage,
                    weeklyUsage: claudeMonitor.weeklyUsage,
                    status: claudeMonitor.status,
                    lastUpdated: claudeMonitor.lastUpdated
                ) {
                    ClaudeAnalyticsWebView(monitor: claudeMonitor)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    "Lancer automatiquement à l’ouverture de session",
                    isOn: Binding(
                        get: { codexMonitor.launchAtLoginEnabled },
                        set: { codexMonitor.setLaunchAtLoginEnabled($0) }
                    )
                )
                .toggleStyle(.switch)

                if let launchAtLoginMessage = codexMonitor.launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                Button("Ouvrir dans le navigateur", systemImage: "safari") {
                    if selectedProvider == .codex {
                        codexMonitor.openInBrowser()
                    } else {
                        claudeMonitor.openInBrowser()
                    }
                }

                if selectedProvider == .claude {
                    Button("Coller le lien de connexion", systemImage: "doc.on.clipboard") {
                        claudeMonitor.loadLoginLinkFromPasteboard()
                    }
                }

                Spacer()

                Button("Actualiser", systemImage: "arrow.clockwise") {
                    codexMonitor.refresh()
                    claudeMonitor.refresh()
                }

                Button("Quitter") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .onAppear {
            codexMonitor.refreshLaunchAtLoginStatus()
        }
    }
}

private struct ProviderUsageView<WebContent: View>: View {
    let fiveHourUsage: Int?
    let weeklyUsage: Int?
    let status: String
    let lastUpdated: Date?
    let webContent: WebContent

    init(
        fiveHourUsage: Int?,
        weeklyUsage: Int?,
        status: String,
        lastUpdated: Date?,
        @ViewBuilder webContent: () -> WebContent
    ) {
        self.fiveHourUsage = fiveHourUsage
        self.weeklyUsage = weeklyUsage
        self.status = status
        self.lastUpdated = lastUpdated
        self.webContent = webContent()
    }

    var body: some View {
        UsageHeader(fiveHourUsage: fiveHourUsage, weeklyUsage: weeklyUsage)

        HStack {
            Text(status)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            if let lastUpdated {
                Text(lastUpdated, format: .dateTime.hour().minute())
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)

        Divider()

        webContent
            .frame(minWidth: 520, idealWidth: 620, minHeight: 500, idealHeight: 620)
    }
}

private struct UsageHeader: View {
    let fiveHourUsage: Int?
    let weeklyUsage: Int?

    var body: some View {
        HStack(spacing: 20) {
            UsageValue(title: "5 heures", value: fiveHourUsage)
            UsageValue(title: "Semaine", value: weeklyUsage)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct UsageValue: View {
    let title: LocalizedStringResource
    let value: Int?

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map { "\($0) %" } ?? "— %")
                .font(.title2.monospacedDigit())
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AnalyticsWebView: NSViewRepresentable {
    let monitor: UsageMonitor

    func makeCoordinator() -> Coordinator {
        Coordinator(monitor: monitor)
    }

    func makeNSView(context: Context) -> WKWebView {
        monitor.prepareWebViewForPresentation()
        return monitor.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.monitor.hostWebViewInBackground()
    }

    final class Coordinator {
        let monitor: UsageMonitor

        init(monitor: UsageMonitor) {
            self.monitor = monitor
        }
    }
}

#Preview {
    ContentView(
        codexMonitor: UsageMonitor(),
        claudeMonitor: ClaudeUsageMonitor()
    )
        .frame(width: 620, height: 760)
}
#else
@main
struct CodexUsageMenuApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Cette plateforme n’est pas encore prise en charge.")
                .padding()
        }
    }
}
#endif
