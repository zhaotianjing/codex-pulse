import SwiftUI

struct UsageView: View {
    @ObservedObject var store: UsageStore
    let onCollapse: () -> Void
    let onQuit: () -> Void

    private let accent = Color(red: 0.31, green: 0.90, blue: 0.72)
    private let violet = Color(red: 0.55, green: 0.48, blue: 1.0)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color(red: 0.045, green: 0.055, blue: 0.082).opacity(0.96),
                    Color(red: 0.065, green: 0.071, blue: 0.11).opacity(0.94)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            Circle()
                .fill(accent.opacity(0.09))
                .frame(width: 230, height: 230)
                .blur(radius: 48)
                .offset(x: -135, y: -205)

            Circle()
                .fill(violet.opacity(0.10))
                .frame(width: 220, height: 220)
                .blur(radius: 58)
                .offset(x: 155, y: 190)

            content
                .padding(18)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .padding(6)
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        VStack(spacing: 14) {
            header

            if let snapshot = store.snapshot, let primary = snapshot.primaryBucket {
                primaryUsage(primary, snapshot: snapshot)
                additionalLimits(snapshot.additionalBuckets)
                tokenStats(snapshot)
            } else {
                loadingOrError
            }

            Spacer(minLength: 0)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.95), violet.opacity(0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 0.035, green: 0.045, blue: 0.07))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("CODEX PULSE")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(1.0)
                Text("Usage Monitor")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let plan = store.snapshot?.planType {
                Text(displayPlan(plan))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(accent.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(accent.opacity(0.24), lineWidth: 1))
            }

            iconButton("minus", help: "Collapse to compact bar", action: onCollapse)
            iconButton("power", help: "Quit", action: onQuit)
        }
    }

    private func primaryUsage(_ bucket: RateLimitBucket, snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 9)

                Circle()
                    .trim(from: 0, to: max(0.012, bucket.remainingPercent / 100))
                    .stroke(
                        AngularGradient(
                            colors: [accent, Color.cyan, violet, accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: accent.opacity(0.28), radius: 8)

                VStack(spacing: 0) {
                    Text("\(Int(bucket.remainingPercent.rounded()))%")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("AVAILABLE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: statusColor.opacity(0.8), radius: 4)
                    Text("MAIN LIMIT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                }

                Text(windowTitle(bucket))
                    .font(.system(size: 17, weight: .bold, design: .rounded))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Used \(formatPercent(bucket.usedPercent))")
                        .foregroundStyle(.secondary)
                    Text(resetDescription(bucket.resetsAt))
                        .foregroundStyle(accent.opacity(0.92))
                }
                .font(.system(size: 11, weight: .medium))

                if snapshot.resetCredits > 0 {
                    Label("Resets available: \(snapshot.resetCredits)", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(violet.opacity(0.95))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    @ViewBuilder
    private func additionalLimits(_ buckets: [RateLimitBucket]) -> some View {
        if !buckets.isEmpty {
            VStack(spacing: 9) {
                HStack {
                    Text("OTHER LIMIT POOLS")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.45)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Not the active model")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.72))
                }
                .help("These are account-level limit pools, not the model selected for the current thread.")

                ForEach(buckets.prefix(2)) { bucket in
                    VStack(spacing: 7) {
                        HStack {
                            Text(bucket.name)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("Remaining \(Int(bucket.remainingPercent.rounded()))%")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(accent)
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [accent, violet],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: proxy.size.width * bucket.remainingPercent / 100)
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(cardBackground)
            .overlay(cardBorder)
        }
    }

    private func tokenStats(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 10) {
            metricCard(
                title: "LIFETIME TOKENS",
                value: compactNumber(snapshot.lifetimeTokens),
                icon: "sum"
            )
            metricCard(
                title: "PEAK DAY",
                value: compactNumber(snapshot.peakDailyTokens),
                icon: "chart.line.uptrend.xyaxis"
            )
        }
    }

    private func metricCard(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(violet)
                .frame(width: 27, height: 27)
                .background(violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.45)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private var loadingOrError: some View {
        VStack(spacing: 14) {
            Spacer()
            switch store.state {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
                Text("Connecting to Codex…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.orange)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 240)
                Button("Retry") { store.refresh() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent.opacity(0.75))
            case .live:
                EmptyView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(statusText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                store.refresh()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.isRefreshing ? 180 : 0))
                    Text("Refresh")
                }
                .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.isRefreshing ? .secondary : accent)
            .disabled(store.isRefreshing)
            .help("Refresh now")
        }
        .padding(.horizontal, 3)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.045))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.045), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var statusColor: Color {
        switch store.state {
        case .live: return accent
        case .connecting: return .yellow
        case .failed: return .orange
        }
    }

    private var statusText: String {
        switch store.state {
        case .connecting:
            return "Syncing"
        case .failed:
            return "Sync failed"
        case .live:
            if let date = store.lastUpdated {
                return "Live · \(date.formatted(date: .omitted, time: .shortened)) · refreshes every 60s"
            }
            return "Live · refreshes every 60s"
        }
    }

    private func displayPlan(_ plan: String) -> String {
        switch plan.lowercased() {
        case "prolite": return "PRO"
        case "self_serve_business_usage_based": return "BUSINESS"
        case "enterprise_cbp_usage_based": return "ENTERPRISE"
        default: return plan.replacingOccurrences(of: "_", with: " ").uppercased()
        }
    }

    private func windowTitle(_ bucket: RateLimitBucket) -> String {
        guard let minutes = bucket.windowDurationMinutes else { return bucket.name }
        if minutes % 10_080 == 0 { return durationTitle(minutes / 10_080, unit: "week") }
        if minutes % 1_440 == 0 { return durationTitle(minutes / 1_440, unit: "day") }
        if minutes % 60 == 0 { return durationTitle(minutes / 60, unit: "hour") }
        return durationTitle(minutes, unit: "minute")
    }

    private func durationTitle(_ value: Int, unit: String) -> String {
        "\(value)-\(unit) window"
    }

    private func resetDescription(_ date: Date?) -> String {
        guard let date else { return "Reset time unavailable" }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "Resetting soon" }

        let days = Int(interval / 86_400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86_400) / 3_600)
        if days > 0 { return "Resets in \(days)d \(hours)h" }

        let minutes = max(1, Int(interval / 60))
        if hours > 0 { return "Resets in \(hours)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }

    private func compactNumber(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let number = Double(value)
        if number >= 1_000_000_000 { return String(format: "%.1fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }

    private func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}

struct CompactUsageView: View {
    @ObservedObject var store: UsageStore
    let onExpand: () -> Void
    let onQuit: () -> Void

    private let accent = Color(red: 0.31, green: 0.90, blue: 0.72)
    private let violet = Color(red: 0.55, green: 0.48, blue: 1.0)

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent, violet],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.035, green: 0.045, blue: 0.07))
            }
            .frame(width: 31, height: 31)

            VStack(alignment: .leading, spacing: 2) {
                if let bucket = store.snapshot?.primaryBucket {
                    Text("Codex · \(Int(bucket.remainingPercent.rounded()))% available")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("Used \(Int(bucket.usedPercent.rounded()))%")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Codex Pulse")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Text(compactStatus)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 25, height: 25)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .help("Expand")

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    LinearGradient(
                        colors: [
                            Color(red: 0.045, green: 0.055, blue: 0.082).opacity(0.97),
                            Color(red: 0.065, green: 0.071, blue: 0.11).opacity(0.95)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
        }
        .padding(5)
        .preferredColorScheme(.dark)
        .onTapGesture(count: 2, perform: onExpand)
    }

    private var compactStatus: String {
        switch store.state {
        case .connecting: return "Syncing"
        case .live: return "Live"
        case .failed: return "Sync failed"
        }
    }
}
