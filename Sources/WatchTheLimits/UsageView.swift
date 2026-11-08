import AppKit
import SwiftUI
import UsageCore

struct UsageView: View {
    @ObservedObject var model: UsageModel
    private let design = PanelDesign.shared
    private var layout: PanelDesign.Layout { design.layout }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.phase.requiresSetup {
                setup
            } else {
                limits
                availableResets
                settings
            }
            footer
        }
        .frame(width: layout.width, height: model.phase.requiresSetup ? layout.setupHeight : nil)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(PanelDesign.color("foreground"))
        .accessibilityIdentifier("usage-panel")
        .onAppear { model.panelDidOpen() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: layout.headerSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: layout.valueSpacing) {
                PanelText("Watch the Limits", role: "Title")
                Spacer(minLength: 0)
                if !model.phase.requiresSetup, let plan = model.planTitle {
                    PanelText(plan).foregroundStyle(PanelDesign.color("foreground-muted"))
                }
            }
            if !model.phase.requiresSetup {
                status
                if model.phase.showsRefreshFailure, model.hasPanelData, let updated = model.lastUpdated {
                    PanelText("Last updated at " + updated.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(PanelDesign.color("foreground-muted"))
                }
            }
        }
        .padding(.horizontal, layout.padding)
        .padding(.top, layout.padding)
        .padding(.bottom, layout.headerBottom)
    }

    @ViewBuilder private var status: some View {
        if model.phase.showsRefreshFailure {
            HStack(spacing: layout.rowSpacing) {
                PanelText("Couldn’t refresh")
                    .foregroundStyle(PanelDesign.color("foreground"))
                    .help(model.errorMessage ?? "Could not refresh usage.")
                Spacer(minLength: 0)
                Button { model.refresh() } label: {
                    HStack(spacing: layout.buttonSpacing) {
                        if model.phase == .retrying {
                            spinner
                        } else {
                            Image(nsImage: PanelDesign.icon("refresh"))
                                .frame(width: layout.refreshIconSize, height: layout.refreshIconSize)
                                .accessibilityHidden(true)
                        }
                        Text(model.phase == .retrying ? "Trying again..." : "Try again")
                    }
                }
                .buttonStyle(PanelButtonStyle())
                .disabled(model.phase == .retrying)
                .accessibilityIdentifier("retry-usage")
            }
            .frame(height: layout.controlHeight)
        } else if model.phase == .loading {
            HStack(spacing: layout.rowSpacing) {
                spinner
                PanelText("Loading")
            }
            .foregroundStyle(PanelDesign.color("foreground-muted"))
        } else if let date = model.lastUpdated {
            PanelText("Updated at " + date.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(PanelDesign.color("foreground-muted"))
        }
    }

    private var spinner: some View {
        ProgressView().controlSize(.mini)
            .frame(width: layout.spinnerSize, height: layout.spinnerSize)
            .accessibilityLabel(model.phase == .loading ? "Loading usage" : "Retrying usage")
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            ForEach(model.quotas) { quota in
                UsageLimitView(quota: quota, now: model.now, stale: model.hasPanelData && model.isStale)
            }
        }
        .padding(layout.padding)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSectionHeader(title: "Settings", expanded: $model.showSettings)
                .padding(layout.disclosurePadding)
            CollapsibleSectionContent(expanded: model.showSettings) {
                VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                    HStack(spacing: layout.labelSpacing) {
                        PanelText("Menu bar", role: "Label")
                        Spacer(minLength: 0)
                        MenuBarSelector(selection: Binding(get: { model.menuBarDisplay },
                                                           set: { model.setMenuBarDisplay($0) }))
                    }
                    .frame(height: layout.controlHeight)
                    HStack(spacing: layout.labelSpacing) {
                        PanelText("Launch at login", role: "Label")
                        Spacer(minLength: 0)
                        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                               set: { model.setLaunchAtLogin($0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.regular)
                            .accessibilityIdentifier("launch-at-login")
                    }
                    .frame(height: layout.controlHeight)
                    VStack(alignment: .leading, spacing: layout.controlRowSpacing) {
                        HStack(spacing: layout.labelSpacing) {
                            PanelText("Codex location", role: "Label")
                            Spacer(minLength: 0)
                            Button("Choose") { model.chooseExecutable() }
                                .buttonStyle(PanelButtonStyle())
                                .accessibilityIdentifier("choose-codex")
                        }
                        .frame(height: layout.controlHeight)
                        PanelText(model.displayedExecutablePath)
                            .foregroundStyle(PanelDesign.color("foreground-muted"))
                            .truncationMode(.head)
                            .help(model.displayedExecutablePath)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, layout.padding)
                .padding(.bottom, layout.padding)
            }
        }
    }

    private var availableResets: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSectionHeader(title: "Available resets", count: model.resetCount,
                               stale: model.isStale, expanded: $model.showAvailableResets)
                .padding(layout.disclosurePadding)
            CollapsibleSectionContent(expanded: model.showAvailableResets) {
                VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                    if model.resetSummary?.count == 0 || model.resetCredits.isEmpty {
                        PanelText(model.resetSummary?.count == 0 ? "No available resets" : "No data")
                            .foregroundStyle(PanelDesign.color("foreground-muted"))
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("reset-availability-message")
                    } else {
                        ForEach(model.resetCredits) { credit in
                            resetRow(credit)
                        }
                    }
                }
                .padding(.horizontal, layout.padding)
                .padding(.bottom, layout.padding)
            }
        }
    }

    private func resetRow(_ credit: ResetCredit) -> some View {
        let confirming = model.resetInteraction.confirmationID == credit.id
        let processing = model.resetInteraction.processing?.creditID == credit.id
        let stale = model.isStale
        return VStack(alignment: .leading, spacing: layout.controlRowSpacing) {
            HStack(spacing: layout.labelSpacing) {
                PanelText(credit.displayTitle, role: "Label")
                    .foregroundStyle(PanelDesign.color(stale ? "foreground-subtle" : "foreground"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(credit.description ?? credit.displayTitle)
                Button { model.activateReset(credit) } label: {
                    HStack(spacing: layout.buttonSpacing) {
                        if processing {
                            ProgressView().controlSize(.mini)
                                .frame(width: layout.spinnerSize, height: layout.spinnerSize)
                                .accessibilityHidden(true)
                        }
                        Text(processing ? "Processing" : confirming ? "Confirm reset" : "Use reset")
                    }
                    .fixedSize()
                }
                .buttonStyle(PanelButtonStyle(prominent: confirming))
                .disabled(!model.canUseReset(credit))
                .accessibilityIdentifier("reset-action-" + credit.id)
                .accessibilityLabel((confirming ? "Confirm reset: " : "Use reset: ") + credit.displayTitle)
            }
            .frame(height: layout.controlHeight)
            if let expiration = credit.expirationText(at: model.now) {
                PanelText(expiration)
                    .foregroundStyle(PanelDesign.color(stale ? "foreground-subtle" : "foreground-muted"))
                    .help(expiration)
            }
            if model.resetInteraction.errorID == credit.id {
                PanelText("Couldn’t confirm reset")
                    .foregroundStyle(PanelDesign.color(stale ? "foreground-subtle" : "foreground-muted"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, layout.errorPadding)
                    .accessibilityIdentifier("reset-error-" + credit.id)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var setup: some View {
        VStack(spacing: layout.sectionSpacing) {
            Text(model.phase == .codexMissing ? "Codex not found" : "Sign in to Codex to see your usage")
                .font(design.textStyle("Caption").font)
                .multilineTextAlignment(.center)
            Button(model.phase == .codexMissing ? "Locate Codex" : "Sign-in instructions") {
                if model.phase == .codexMissing { model.chooseExecutable() }
                else { openProject("#setup") }
            }
            .buttonStyle(PanelButtonStyle())
            .accessibilityIdentifier("setup-codex")
        }
        .padding(.horizontal, layout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("View on GitHub") { openProject("") }
                .buttonStyle(PanelButtonStyle())
                .accessibilityIdentifier("view-github")
            Spacer(minLength: 0)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(PanelButtonStyle())
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit Watch the Limits")
        }
        .padding(layout.padding)
    }

    private func openProject(_ fragment: String) {
        NSWorkspace.shared.open(URL(string: "https://github.com/alisov66/watch-the-limits\(fragment)")!)
    }
}

private struct UsageLimitView: View {
    let quota: PanelQuota
    let now: Date
    let stale: Bool
    private let layout = PanelDesign.shared.layout

    var body: some View {
        let remaining = quota.remainingPercent(at: now)
        let expired = quota.window?.hasExpired(at: now) == true
        VStack(alignment: .leading, spacing: layout.rowSpacing) {
            HStack(spacing: layout.labelSpacing) {
                PanelText(quota.title, role: "Label")
                Spacer(minLength: 0)
                Group {
                    if let remaining {
                        HStack(spacing: layout.valueSpacing) {
                            PanelText("\(remaining)%", role: "Value")
                            PanelText("left", role: "Value")
                        }
                    } else {
                        PanelText("—", role: "Value")
                    }
                }
                .foregroundStyle(PanelDesign.color(stale ? "foreground-subtle" : "foreground"))
            }
            .frame(height: PanelDesign.shared.textStyle("Value").lineHeight)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(PanelDesign.color("progress/track"))
                    if let remaining, remaining > 0 {
                        Capsule().fill(PanelDesign.color(stale ? "progress/fill-stale" : "progress/fill"))
                            .frame(width: geometry.size.width * CGFloat(remaining) / 100)
                    }
                }
            }
            .frame(height: layout.progressHeight)
            .accessibilityLabel(quota.title + " remaining quota")
            .accessibilityValue(remaining.map { "\($0) percent" } ?? "Unavailable")

            HStack(spacing: layout.resetSpacing) {
                if !expired { PanelText("Resets in") }
                PanelText(quota.resetText(at: now))
                Spacer(minLength: 0)
            }
            .foregroundStyle(PanelDesign.color(stale ? "foreground-subtle" : "foreground-muted"))
            .help(quota.window?.resetsAt.map { Date(timeIntervalSince1970: $0).formatted(date: .complete, time: .shortened) }
                  ?? "Reset time unavailable")
        }
    }
}

/// Preserve the content's natural layout while animating its clipped viewport height.
private struct CollapsibleSectionContent<Content: View>: View {
    let expanded: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelPreviewReduceMotion) private var previewReduceMotion

    var body: some View {
        SectionRevealLayout(progress: expanded ? 1 : 0) {
            content
        }
            .clipped()
            .allowsHitTesting(expanded)
            .disabled(!expanded)
            .accessibilityHidden(!expanded)
            .animation(reduceMotion || previewReduceMotion ? nil : PanelDesign.shared.motion.sectionAnimation, value: expanded)
    }
}

private struct SectionRevealLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: natural.height * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct PanelSectionHeader: View {
    let title: String
    var count: Int? = nil
    var stale = false
    @Binding var expanded: Bool
    @StateObject private var hover = PanelHoverState()
    @Environment(\.panelPreviewHover) private var previewHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelPreviewReduceMotion) private var previewReduceMotion
    private let layout = PanelDesign.shared.layout

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: layout.rowSpacing) {
                PanelText(title, role: "Label")
                if let count {
                    PanelText("\(count)")
                        .foregroundStyle(PanelDesign.color(stale ? "foreground-subtle" : "foreground-muted"))
                        .padding(.horizontal, layout.rowSpacing)
                        .frame(minWidth: layout.counterSize, minHeight: layout.counterSize)
                        .background(PanelDesign.color("control/fill"),
                                    in: RoundedRectangle(cornerRadius: layout.counterRadius))
                        .accessibilityLabel("\(count) available resets")
                }
                Spacer(minLength: 0)
                Image(nsImage: PanelDesign.icon("nav-arrow"))
                    .frame(width: layout.navIconSize, height: layout.navIconSize)
                    .foregroundStyle(PanelDesign.color("control/foreground"))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(reduceMotion || previewReduceMotion ? nil : PanelDesign.shared.motion.sectionAnimation, value: expanded)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(PanelDesign.color("foreground-muted"))
            .padding(.horizontal, layout.disclosurePadding)
            .frame(height: layout.controlHeight)
            .contentShape(Capsule())
            .background(previewHover || hover.isHovered ? PanelDesign.color("control/fill-hover") : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(title == "Settings" ? "toggle-settings" : "toggle-resets")
    }
}

private struct MenuBarSelector: View {
    @Binding var selection: MenuBarDisplay
    private let layout = PanelDesign.shared.layout
    private let options: [MenuBarDisplay] = [.fiveHour, .weekly, .both]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                Button { selection = option } label: {
                    Text(option == .fiveHour ? "5-hour" : option == .weekly ? "Weekly" : "Both")
                        .font(PanelDesign.shared.textStyle("Button").font)
                        .foregroundStyle(PanelDesign.color(selection == option ? "foreground-on-fill" : "control/foreground"))
                        .padding(.horizontal, layout.controlPadding)
                        .frame(height: layout.controlHeight)
                }
                .buttonStyle(PanelSelectorButtonStyle(selected: selection == option))
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .background(PanelDesign.color("selector/fill"), in: RoundedRectangle(cornerRadius: layout.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar display")
        .accessibilityIdentifier("menu-bar-display")
    }
}
