#if os(macOS)
import AppKit
import Observation
import SwiftUI
import WebKit

private let claudeUsageURL = URL(string: "https://claude.ai/settings/usage")!

@MainActor
@Observable
final class ClaudeUsageMonitor: NSObject, WKNavigationDelegate {
    var fiveHourUsage: Int?
    var weeklyUsage: Int?
    var status = "Connexion à Claude…"
    var lastUpdated: Date?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let backgroundWindow: NSWindow
    @ObservationIgnored private let backgroundContainer: NSView
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var hasRedirectedAfterLogin = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 620))
        backgroundContainer = container
        backgroundWindow = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 620),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        super.init()

        backgroundWindow.contentView = container
        backgroundWindow.alphaValue = 0.01
        backgroundWindow.ignoresMouseEvents = true
        backgroundWindow.isReleasedWhenClosed = false
        backgroundWindow.collectionBehavior = [.stationary, .transient, .ignoresCycle]

        webView.navigationDelegate = self
        hostWebViewInBackground()
        webView.load(URLRequest(url: claudeUsageURL))
        startupTask = Task { [weak self] in
            await self?.loadUsageAtStartup()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        startupTask?.cancel()
        refreshTimer?.invalidate()
    }

    var fiveHourMenuTitle: String {
        fiveHourUsage.map(String.init) ?? "—"
    }

    var weeklyMenuTitle: String {
        weeklyUsage.map(String.init) ?? "—"
    }

    var compactMenuTitle: String {
        "\(fiveHourMenuTitle)·\(weeklyMenuTitle)%"
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
        guard let url = webView.url, isAuthenticatedClaudePage(url) else {
            status = "Connectez-vous à Claude ci-dessous."
            return
        }

        status = "Actualisation…"
        if isUsageURL(url) {
            webView.reload()
        } else {
            webView.load(URLRequest(url: claudeUsageURL))
        }
    }

    func openInBrowser() {
        NSWorkspace.shared.open(claudeUsageURL)
    }

    func loadLoginLinkFromPasteboard() {
        guard
            let pastedValue = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: pastedValue),
            url.scheme == "https",
            isTrustedLoginLinkHost(url.host)
        else {
            status = "Copiez d’abord le lien sécurisé reçu par e-mail."
            return
        }

        status = "Ouverture du lien de connexion Claude…"
        webView.load(URLRequest(url: url))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let host = navigationAction.request.url?.host?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        if host == "accounts.google.com" ||
            host.hasSuffix(".accounts.google.com") ||
            host == "appleid.apple.com" ||
            host.hasSuffix(".appleid.apple.com")
        {
            status = "Google et Apple bloquent la connexion intégrée. Utilisez « Continuer avec l’e-mail », copiez le lien reçu, puis collez-le avec le bouton sous la page."
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
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

        if isAuthenticatedClaudePage(url), !hasRedirectedAfterLogin {
            hasRedirectedAfterLogin = true
            status = "Connexion réussie. Ouverture de la page d’usage…"
            webView.load(URLRequest(url: claudeUsageURL))
        } else {
            status = "Connectez-vous à Claude ci-dessous."
        }
    }

    private func isUsageURL(_ url: URL) -> Bool {
        isClaudeHost(url.host) && url.path.hasPrefix("/settings/usage")
    }

    private func isAuthenticatedClaudePage(_ url: URL) -> Bool {
        guard isClaudeHost(url.host) else {
            return false
        }

        let path = url.path.lowercased()
        return !path.hasPrefix("/login") && !path.hasPrefix("/signup")
    }

    private func isClaudeHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        return host == "claude.ai" || host.hasSuffix(".claude.ai")
    }

    private func isTrustedLoginLinkHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }

        return host == "claude.ai" ||
            host.hasSuffix(".claude.ai") ||
            host == "anthropic.com" ||
            host.hasSuffix(".anthropic.com")
    }

    private func loadUsageAtStartup() async {
        for _ in 1...3 {
            try? await ContinuousClock().sleep(for: .seconds(3))

            guard !Task.isCancelled, fiveHourUsage == nil || weeklyUsage == nil else {
                return
            }

            guard let url = webView.url else {
                continue
            }

            if isUsageURL(url) {
                await extractUsage()
                return
            }

            if isAuthenticatedClaudePage(url) {
                webView.load(URLRequest(url: claudeUsageURL))
            }
        }
    }

    private func extractUsage() async {
        status = "Lecture des limites Claude…"

        for attempt in 1...15 {
            do {
                let result = try await webView.callAsyncJavaScript(
                    Self.extractionScript,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )

                if
                    let values = result as? [String: Any],
                    let fiveHour = values["fiveHour"] as? NSNumber,
                    let weekly = values["weekly"] as? NSNumber
                {
                    let fiveHourUsed = max(0, min(100, fiveHour.intValue))
                    let weeklyUsed = max(0, min(100, weekly.intValue))
                    fiveHourUsage = 100 - fiveHourUsed
                    weeklyUsage = 100 - weeklyUsed
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

        status = "Limites Claude introuvables dans la page d’usage."
    }

    private static let extractionScript = """
        async function usageFromAPI() {
            try {
                const organizationsResponse = await fetch(
                    "/api/organizations",
                    { credentials: "include" }
                );
                if (!organizationsResponse.ok) return null;

                const payload = await organizationsResponse.json();
                const organizations = Array.isArray(payload)
                    ? payload
                    : payload.organizations;
                for (const organization of organizations ?? []) {
                    const organizationID = organization?.uuid ?? organization?.id;
                    if (!organizationID) continue;

                    const usageResponse = await fetch(
                        `/api/organizations/${encodeURIComponent(organizationID)}/usage`,
                        { credentials: "include" }
                    );
                    if (!usageResponse.ok) continue;

                    const usage = await usageResponse.json();
                    const sessionLimit = usage.limits?.find(
                        limit => limit.kind === "session"
                    );
                    const weeklyLimit = usage.limits?.find(
                        limit => limit.kind === "weekly_all"
                    );
                    const fiveHour =
                        usage.five_hour?.utilization ?? sessionLimit?.percent;
                    const weekly =
                        usage.seven_day?.utilization ?? weeklyLimit?.percent;

                    if (
                        Number.isFinite(fiveHour) &&
                        Number.isFinite(weekly)
                    ) {
                        return {
                            fiveHour: Math.round(fiveHour),
                            weekly: Math.round(weekly)
                        };
                    }
                }
            } catch {
                return null;
            }

            return null;
        }

        const apiUsage = await usageFromAPI();
        if (apiUsage) return apiUsage;

        const percentPattern = /(\\d{1,3}(?:[.,]\\d+)?)\\s*%/;
        const sessionPattern =
            /current session|five[ -]?hour|5\\s*(hour|hr|h|heures?)|session actuelle/i;
        const weeklyPattern =
            /all models|tous les modèles|tous les modeles/i;
        const anyLimitPattern =
            /current session|five[ -]?hour|5\\s*(hour|hr|h|heures?)|all models|weekly|week limit|hebdomadaire|semaine/i;

        function percentage(text) {
            const match = text.match(percentPattern);
            if (!match) return null;
            const value = Number(match[1].replace(",", "."));
            return Number.isFinite(value) && value >= 0 && value <= 100
                ? Math.round(value)
                : null;
        }

        function progressValue(container) {
            const progress = container.querySelector(
                '[role="progressbar"], progress, [aria-valuenow]'
            );
            if (!progress) return null;

            const raw =
                progress.getAttribute("aria-valuenow") ??
                progress.getAttribute("value");
            const value = Number(raw);
            if (Number.isFinite(value) && value >= 0 && value <= 100) {
                return Math.round(value);
            }

            const width = progress.style?.width || "";
            return percentage(width);
        }

        function usageFor(labelPattern) {
            const elements = [...document.querySelectorAll(
                "h1, h2, h3, h4, h5, h6, p, span, div, dt, dd"
            )];
            const candidates = elements
                .map(element => ({
                    element,
                    label: (element.innerText || "").trim()
                }))
                .filter(candidate =>
                    candidate.label &&
                    candidate.label.length <= 180 &&
                    labelPattern.test(candidate.label)
                )
                .sort((left, right) => left.label.length - right.label.length);

            for (const candidate of candidates) {
                const element = candidate.element;
                let container = element;
                for (let depth = 0; container && depth < 7; depth += 1) {
                    const progress = progressValue(container);
                    if (progress !== null) return progress;

                    const lines = (container.innerText || "")
                        .split(/\\n+/)
                        .map(line => line.trim())
                        .filter(Boolean);
                    const labelIndex = lines.findIndex(line => labelPattern.test(line));
                    if (labelIndex >= 0) {
                        for (
                            let index = labelIndex;
                            index < Math.min(lines.length, labelIndex + 8);
                            index += 1
                        ) {
                            if (index > labelIndex && anyLimitPattern.test(lines[index])) {
                                break;
                            }
                            const value = percentage(lines[index]);
                            if (value !== null) return value;
                        }
                    }
                    container = container.parentElement;
                }
            }
            return null;
        }

        return {
            fiveHour: usageFor(sessionPattern),
            weekly: usageFor(weeklyPattern)
        };
    """
}

struct ClaudeAnalyticsWebView: NSViewRepresentable {
    let monitor: ClaudeUsageMonitor

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
        let monitor: ClaudeUsageMonitor

        init(monitor: ClaudeUsageMonitor) {
            self.monitor = monitor
        }
    }
}
#endif
