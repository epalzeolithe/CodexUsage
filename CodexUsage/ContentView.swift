import SwiftUI

#if os(macOS)
import AppKit
import AuthenticationServices
import Observation
import WebKit

private let analyticsURL = URL(
    string: "https://chatgpt.com/codex/cloud/settings/analytics#usage"
)!

@main
struct CodexUsageMenuApp: App {
    @State private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            MenuBarUsageLabel(
                fiveHourTitle: monitor.fiveHourMenuTitle,
                weeklyTitle: monitor.weeklyMenuTitle,
                accessibilityTitle: monitor.accessibilityMenuTitle
            )
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarUsageLabel: View {
    let fiveHourTitle: String
    let weeklyTitle: String
    let accessibilityTitle: String

    var body: some View {
        Image(nsImage: menuBarImage)
            .accessibilityLabel(accessibilityTitle)
    }

    private var menuBarImage: NSImage {
        let image = NSImage(
            size: NSSize(width: 52, height: 22),
            flipped: false
        ) { rect in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]

            NSString(string: weeklyTitle).draw(
                in: NSRect(x: 0, y: 0, width: rect.width, height: 11),
                withAttributes: attributes
            )
            NSString(string: fiveHourTitle).draw(
                in: NSRect(x: 0, y: 11, width: rect.width, height: 11),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
@Observable
final class UsageMonitor: NSObject, WKNavigationDelegate {
    var fiveHourUsage: Int?
    var weeklyUsage: Int?
    var status = "Connexion à ChatGPT…"
    var lastUpdated: Date?

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

        backgroundWindow.contentView = backgroundContainer
        backgroundWindow.alphaValue = 0.01
        backgroundWindow.ignoresMouseEvents = true
        backgroundWindow.isReleasedWhenClosed = false
        backgroundWindow.collectionBehavior = [.stationary, .transient, .ignoresCycle]

        webView.navigationDelegate = self
        hostWebViewInBackground()
        requestPasskeyAccessIfNeeded()
        webView.load(URLRequest(url: analyticsURL))
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
        guard webView.url?.absoluteString.contains("/codex/cloud/settings/analytics") == true else {
            status = "Connectez-vous à ChatGPT ci-dessous."
            return
        }
        status = "Actualisation…"
        webView.reload()
    }

    func openInBrowser() {
        NSWorkspace.shared.open(analyticsURL)
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

        if isAnalyticsURL(url) {
            Task {
                await extractUsage()
            }
            return
        }

        if isAuthenticatedChatGPTPage(url), !hasRedirectedAfterLogin {
            hasRedirectedAfterLogin = true
            status = "Connexion réussie. Ouverture de la page d’usage…"
            webView.load(URLRequest(url: analyticsURL))
        } else {
            status = "Connectez-vous à ChatGPT ci-dessous."
        }
    }

    private func isAnalyticsURL(_ url: URL) -> Bool {
        isChatGPTHost(url.host) &&
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
        const lines = (document.body?.innerText || "")
            .split(/\\n+/)
            .map(line => line.trim())
            .filter(Boolean);

        function usageNear(pattern) {
            const index = lines.findIndex(line => pattern.test(line));
            if (index < 0) return null;

            // Each usage card exposes its percentage on the label line or just
            // after it. Looking behind the label can pick the previous card.
            const context = lines.slice(index, Math.min(lines.length, index + 4));
            for (const line of context) {
                const match = line.match(/(\\d{1,3}(?:[.,]\\d+)?)\\s*%/);
                if (match) {
                    return Math.round(Number(match[1].replace(",", ".")));
                }
            }
            return null;
        }

        const pageText = lines.join(" ");
        const visiblePercentages = [...pageText.matchAll(/(\\d{1,3}(?:[.,]\\d+)?)\\s*%/g)]
            .map(match => Math.round(
                Number(match[1].replace(",", "."))
            ));

        const labeledFiveHour = usageNear(
            /5\\s*(hour|hr|h|heures?)|five[ -]?hour|session limit|limite de session/i
        );
        const labeledWeekly = usageNear(
            /weekly|week limit|semaine|hebdomadaire|limite hebdo/i
        );

        return {
            fiveHour: labeledFiveHour ?? visiblePercentages[0] ?? null,
            weekly: labeledWeekly ?? visiblePercentages[1] ?? null
        };
    })();
    """
}

struct ContentView: View {
    let monitor: UsageMonitor

    var body: some View {
        VStack(spacing: 12) {
            UsageHeader(
                fiveHourUsage: monitor.fiveHourUsage,
                weeklyUsage: monitor.weeklyUsage
            )

            HStack {
                Text(monitor.status)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                if let lastUpdated = monitor.lastUpdated {
                    Text(lastUpdated, format: .dateTime.hour().minute())
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)

            Divider()

            AnalyticsWebView(monitor: monitor)
                .frame(minWidth: 520, idealWidth: 620, minHeight: 500, idealHeight: 620)

            Divider()

            HStack {
                Button("Autoriser les clés d’accès", systemImage: "key") {
                    monitor.requestPasskeyAccess()
                }

                Button("Ouvrir dans le navigateur", systemImage: "safari") {
                    monitor.openInBrowser()
                }

                Spacer()

                Button("Actualiser", systemImage: "arrow.clockwise") {
                    monitor.refresh()
                }

                Button("Quitter") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
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
    ContentView(monitor: UsageMonitor())
        .frame(width: 620, height: 760)
}
#else
@main
struct CodexUsageMenuApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Cette application est disponible sur macOS.")
                .padding()
        }
    }
}
#endif
