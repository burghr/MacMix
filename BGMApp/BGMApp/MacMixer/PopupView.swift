import SwiftUI
import CoreAudio

struct PopupView: View {
    @EnvironmentObject var model: MixerModel

    private let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let err = model.startupError {
                errorBanner(err)
            } else if !model.running {
                startingBanner
            } else {
                outputSection
                Divider().padding(.horizontal, 12)
                masterSection
                Divider().padding(.horizontal, 12)
                appsSection
            }
        }
        .frame(width: width)
        .onAppear { if model.running { model.refreshAll() } }
    }

    // ── Header ────────────────────────────────────────────────────────────────

    private var header: some View {
        HStack {
            Text("MacMixer")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // ── Output picker ───────────────────────────────────────────────────────────

    private var outputSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Picker("", selection: Binding(
                get: { model.currentOutputID },
                set: { model.selectOutput($0) }
            )) {
                ForEach(model.outputDevices, id: \.deviceID) { dev in
                    Text(dev.name).tag(dev.deviceID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // ── Master ────────────────────────────────────────────────────────────────────

    private var masterSection: some View {
        VolumeRow(
            icon: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            title: "Master",
            iconTint: .primary,
            value: Binding(get: { model.masterVolume }, set: { model.setMaster($0) }),
            range: 0...1,
            trailing: {
                if model.hasMute {
                    Button(action: { model.toggleMute() }) {
                        Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(model.muted ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // ── Per-app sliders ───────────────────────────────────────────────────────────

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apps")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ScrollView {
                VStack(spacing: 0) {
                    if model.visibleApps.isEmpty {
                        Text(model.hiddenApps.isEmpty ? "No open apps" : "No visible apps")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }

                    ForEach(model.visibleApps) { app in
                        appRow(app, hidden: false)
                    }

                    if model.showingHidden && !model.hiddenApps.isEmpty {
                        Divider().padding(.horizontal, 12).padding(.vertical, 4)
                        Text("Hidden")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 2)
                        ForEach(model.hiddenApps) { app in
                            appRow(app, hidden: true)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            if !model.hiddenApps.isEmpty {
                Button(action: { model.showingHidden.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: model.showingHidden ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                        Text(model.showingHidden
                             ? "Hide hidden apps"
                             : "Show hidden apps (\(model.hiddenApps.count))")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func appRow(_ app: MixerModel.AppEntry, hidden: Bool) -> some View {
        let boosting = app.volume > MixerModel.normalPercent
        VolumeRow(
            nsIcon: app.icon,
            title: app.name,
            sliderTint: boosting ? .orange : nil,
            value: Binding(
                get: { app.volume },
                set: { newValue in
                    // Snap to exactly 100% (the app's normal level) when nearby.
                    let snapped = abs(newValue - MixerModel.normalPercent) < 4
                        ? MixerModel.normalPercent : newValue
                    model.setVolume(snapped, for: app)
                }
            ),
            range: 0...MixerModel.maxPercent,
            trailing: {
                HStack(spacing: 6) {
                    if boosting {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text("\(Int(app.volume.rounded()))%")
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(boosting ? Color.orange : Color.secondary)
                    Button(action: { hidden ? model.unhide(app) : model.hide(app) }) {
                        Image(systemName: hidden ? "plus.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(hidden ? Color.green : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(hidden ? "Unhide this app" : "Hide this app")
                }
            }
        )
        .opacity(hidden ? 0.6 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // ── Banners ───────────────────────────────────────────────────────────────────

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var startingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Starting…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

/// A labelled volume slider row: icon, title, slider, optional trailing control.
private struct VolumeRow<Trailing: View>: View {
    var icon: String? = nil
    var nsIcon: NSImage? = nil
    let title: String
    var iconTint: Color = .secondary
    var sliderTint: Color? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                iconView
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                trailing()
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(sliderTint)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let nsIcon {
            Image(nsImage: nsIcon).resizable().aspectRatio(contentMode: .fit)
        } else if let icon {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(iconTint)
        }
    }
}
