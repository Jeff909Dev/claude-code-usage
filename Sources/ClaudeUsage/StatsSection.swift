import SwiftUI
import UsageCore

/// API-equivalent spend of this Mac, estimated from Claude Code's transcripts. While the first index runs it shows
/// the totals so far.
struct StatsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        let stats = model.stats
        let summary = model.spendSummary
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "this mac · api-equivalent spend")
                .padding(.bottom, 2)
            HStack(spacing: 0) {
                Text("estimated from local transcripts").layoutPriority(1)
                Spacer(minLength: 8)
                if let terminal = model.terminalAccount { Text("terminal: \(terminal.label)") }
            }
            .font(Typo.ui(style, size: 10))
            .foregroundStyle(Tok.faint)
            .lineLimit(1)
            .padding(.bottom, 8)
            if let progress = model.indexProgress {
                HStack(spacing: 6) {
                    Spinner()
                    Text(StatsText.indexing(progress))
                }
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.muted)
                .padding(.bottom, 8)
            }
            HStack(alignment: .top, spacing: 6) {
                StatTile(title: "today", value: Format.money(micros: stats.todayMicros),
                         note: StatsText.vsAverage(summary.todayVsAverage))
                StatTile(title: "7 days", value: Format.money(micros: stats.last7dMicros),
                         note: StatsText.perDay(summary.dailyAverage7dMicros))
                StatTile(title: "30 days", value: Format.money(micros: stats.last30dMicros),
                         note: StatsText.planMultiple(summary.planMultiple, plans: model.accounts.map(\.plan),
                                                      pricing: model.env.pricing),
                         accentNote: true)
                    .help("API-equivalent spend of the last 30 days against the monthly price of your plans")
            }
            .fixedSize(horizontal: false, vertical: true)
            ActivityLine(parts: StatsText.activity(stats))
                .padding(.top, 8)
            HourlyChart(hours: stats.hourly, peak: summary.peakHour)
            ModelMixBar(mix: stats.modelMix)
            TopProjects(projects: stats.topProjects)
            if let surfaces = model.displayedSnapshot?.surfaces, !surfaces.isEmpty {
                SurfaceLine(surfaces: surfaces)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// A small heading inside the stats section, with an optional reading on the right.
private struct SubHead: View {
    let title: String
    var trailing: String? = nil
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(Tok.muted)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(Typo.num(size: 10)).foregroundStyle(Tok.text2) }
        }
        .font(Typo.ui(style, size: 10))
        .lineLimit(1)
        .padding(.top, 12)
        .padding(.bottom, 5)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var note: String?
    var accentNote = false
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Typo.ui(style, size: 10)).foregroundStyle(Tok.muted)
            Text(value).font(Typo.num(size: 13, weight: .semibold)).foregroundStyle(Tok.text)
            Text(note ?? " ").font(Typo.ui(style, size: 10)).foregroundStyle(accentNote ? Tok.claude : Tok.muted)
                .minimumScaleFactor(0.8)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Tok.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.border, lineWidth: 0.5))
    }
}

/// "18.4M tok · cache hit 92% · 312 msgs · 9 sessions"
private struct ActivityLine: View {
    let parts: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(parts.indices, id: \.self) { i in
                if i > 0 { Text("·").foregroundStyle(Tok.faint) }
                Text(parts[i])
            }
        }
        .font(Typo.num(size: 10))
        .foregroundStyle(Tok.text2)
        .lineLimit(1)
    }
}

/// Cost per hour over the last 24 hours; hovering a bar reads it out in place of the peak.
struct HourlyChart: View {
    let hours: [HourCost]
    let peak: HourCost?
    @Environment(\.themeStyle) private var style
    @State private var hovered: HourCost?

    var body: some View {
        let calendar = Calendar.current
        let maxCost = max(hours.map(\.costMicros).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 0) {
            SubHead(title: "last 24h", trailing: hovered.map { StatsText.hourCost($0, calendar: calendar) }
                        ?? StatsText.peak(peak, calendar: calendar))
            if hours.isEmpty {
                Text("no usage yet").font(Typo.ui(style, size: 10)).foregroundStyle(Tok.faint)
            } else {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(hours.indices, id: \.self) { i in
                        let hour = hours[i]
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(color(hour, isNow: i == hours.count - 1))
                                .frame(height: hour.costMicros > 0
                                       ? max(2, 30 * CGFloat(hour.costMicros) / CGFloat(maxCost)) : 1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hovered = hour } else if hovered == hour { hovered = nil }
                        }
                    }
                }
                .frame(height: 30)
                let labels = StatsText.axis(hours, calendar: calendar)
                HStack(spacing: 0) {
                    ForEach(labels.indices, id: \.self) { i in
                        if i > 0 { Spacer(minLength: 0) }
                        Text(labels[i])
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Tok.faint)
                .padding(.top, 3)
            }
        }
    }

    private func color(_ hour: HourCost, isNow: Bool) -> Color {
        if hour == hovered { return Tok.text }
        if hour.costMicros == 0 { return Tok.track }
        return isNow ? Tok.claude : Tok.claude.opacity(0.7)
    }
}

struct ModelMixBar: View {
    let mix: [ModelShare]
    @Environment(\.themeStyle) private var style

    static func color(_ family: String) -> Color {
        switch family {
        case "Fable": return Tok.claude
        case "Opus": return Tok.suggestion
        case "Sonnet": return Tok.success
        case "Haiku": return Tok.plan
        case "Mythos": return Tok.warning
        default: return Tok.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubHead(title: "model mix · today")
            if mix.isEmpty {
                Text("no usage today").font(Typo.ui(style, size: 10)).foregroundStyle(Tok.faint)
            } else {
                GeometryReader { geo in
                    let room = geo.size.width - 1.5 * CGFloat(mix.count - 1)
                    HStack(spacing: 1.5) {
                        ForEach(mix, id: \.family) { share in
                            Rectangle().fill(Self.color(share.family))
                                .frame(width: max(1, room * share.fraction))
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                HStack(spacing: 10) {
                    ForEach(mix, id: \.family) { share in
                        HStack(spacing: 4) {
                            Text("●").font(.system(size: 8)).foregroundStyle(Self.color(share.family))
                            Text(share.family).foregroundStyle(Tok.text2)
                            Text(Format.percent(share.fraction * 100)).font(Typo.num(size: 10)).foregroundStyle(Tok.muted)
                        }
                    }
                }
                .font(Typo.ui(style, size: 10))
                .lineLimit(1)
                .padding(.top, 5)
            }
        }
    }
}

struct TopProjects: View {
    let projects: [ProjectCost]
    @Environment(\.themeStyle) private var style

    var body: some View {
        let top = max(projects.first?.costMicros ?? 1, 1)
        VStack(alignment: .leading, spacing: 0) {
            SubHead(title: "top projects · today")
            if projects.isEmpty {
                Text("no usage today").foregroundStyle(Tok.faint)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(projects, id: \.project) { project in
                    HStack(spacing: 8) {
                        // The end of a path names the project; drop the start when it doesn't fit.
                        Text(project.project)
                            .foregroundStyle(Tok.text2)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        MiniBar(fraction: Double(project.costMicros) / Double(top))
                            .frame(width: 64)
                        Text(Format.money(micros: project.costMicros))
                            .font(Typo.num(size: 10))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .font(Typo.ui(style, size: 10))
        .lineLimit(1)
    }
}

private struct MiniBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2).fill(Tok.track)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Tok.claude.opacity(0.7))
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
        }
        .frame(height: 4)
    }
}

/// The API's 7-day breakdown by surface (Claude Code, chats, …) for the account shown; the largest stands out.
private struct SurfaceLine: View {
    let surfaces: [SurfaceShare]
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubHead(title: "7d by surface")
            Text(line)
                .font(Typo.ui(style, size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var line: AttributedString {
        let top = surfaces.map(\.percent).max()
        var text = AttributedString()
        for (i, surface) in surfaces.enumerated() {
            var separator = AttributedString(i == 0 ? "" : " · ")
            separator.foregroundColor = Tok.faint
            var part = AttributedString("\(surface.displayName) \(Format.percent(surface.percent))")
            part.foregroundColor = surface.percent == top ? Tok.text2 : Tok.muted
            text += separator + part
        }
        return text
    }
}
