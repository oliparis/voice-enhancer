import SwiftUI
import ServiceManagement

/// Modal settings sheet — secondary configuration.
///
/// Kept behind a gear icon rather than in the main window because:
///   * The main UI is deliberately uncluttered.
///   * Device selection is something you do once, then forget.
///   * Driver status / diagnostics are rarely checked.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audio: AudioViewModel
    @StateObject private var login = LoginItemController()
    @Environment(\.scenePhase) private var scenePhase

    /// Local mirror of the selection so the picker binds cleanly even when
    /// the selected device isn't in the list (e.g. unplugged). The "System
    /// Default" sentinel is represented by nil.
    @State private var pickerSelection: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(audio.t(.settings))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
                Button(audio.t(.done)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

            GroupBox(audio.t(.inputDevice)) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(audio.t(.microphone), selection: $pickerSelection) {
                        Text(audio.t(.systemDefault)).tag(String?.none)
                        ForEach(audio.inputDevices) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Button(audio.t(.reconnectMicrophone)) { audio.retryCapture() }
                        .help(audio.t(.retryCaptureHelp))

                    Text(audio.t(.inputDeviceDescription))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(audio.t(.voiceTuning)) {
                VStack(alignment: .leading, spacing: 14) {
                    // Preview recorder
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            previewControl
                            Spacer()
                        }
                        Text(audio.t(.previewDescription))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(audio.t(.voiceLeveling))
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(Int(audio.compThresholdDb)) dB")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $audio.compThresholdDb, in: -40 ... -10, step: 1)
                        HStack {
                            Text(audio.t(.more))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(audio.t(.less))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(audio.t(.voiceLevelingDescription))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(audio.t(.sibilanceReduction))
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(Int(audio.deesserThresholdDb)) dB")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $audio.deesserThresholdDb, in: -48 ... -16, step: 1)
                        HStack {
                            Text(audio.t(.more))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(audio.t(.less))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(audio.t(.sibilanceDescription))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(audio.t(.virtualDriver)) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(audio.driverAvailable ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(audio.driverAvailable ? audio.t(.installedAndConnected) : audio.t(.notConnected))
                            .font(.callout.weight(.medium))
                        Text(audio.driverAvailable
                             ? audio.t(.driverConnectedDescription)
                             : audio.t(.driverMissingDescription))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(audio.t(.startup)) {
                VStack(alignment: .leading, spacing: 8) {
                Picker(audio.t(.language), selection: $audio.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                Text(audio.t(.languageDescription)).font(.caption).foregroundStyle(.secondary)
                    Toggle(audio.t(.launchAtLogin), isOn: Binding(
                        get: { login.requested }, set: { login.setRequested($0) }))
                    Text(audio.t(.launchAtLoginDescription))
                        .font(.caption).foregroundStyle(.secondary)
                    if login.status == .requiresApproval {
                        Text(audio.t(.loginApprovalRequired))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(audio.t(.openLoginItems)) { SMAppService.openSystemSettingsLoginItems() }
                    } else if login.status == .notFound {
                        Text(audio.t(.loginAppMissing))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = login.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(audio.t(.about)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Voice Enhancer")
                        .font(.system(.body, design: .rounded).bold())
                    Text(audio.t(.openSourceLicensed))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Link("github.com/aheadly-tech/voice-enhancer",
                         destination: URL(string: "https://github.com/aheadly-tech/voice-enhancer")!)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

                }
                .padding(.top, 12)
            }
        }
        .padding(20)
        .onAppear {
            audio.refreshDeviceList()
            login.refresh()
            pickerSelection = audio.selectedInputUID
        }
        .onChange(of: pickerSelection) { new in
            if new != audio.selectedInputUID {
                audio.selectedInputUID = new
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { login.refresh() }
        }
        .onDisappear {
            audio.stopPreviewPlayback()
        }
    }

    // MARK: - Preview control

    @ViewBuilder
    private var previewControl: some View {
        if case .recording(let countdown) = audio.previewState {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(audio.t(.speakNow, countdown))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if audio.previewState == .recorded {
            HStack(spacing: 8) {
                Button { audio.startPreviewPlayback() } label: {
                    Label(audio.t(.play), systemImage: "play.fill")
                }
                .controlSize(.small)

                Button { audio.startPreviewRecording() } label: {
                    Label(audio.t(.rerecord), systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        } else if audio.previewState == .playing {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(audio.t(.previewPlaying))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button { audio.stopPreviewPlayback() } label: {
                    Label(audio.t(.stop), systemImage: "stop.fill")
                }
                .controlSize(.small)
            }
        } else {
            Button { audio.startPreviewRecording() } label: {
                Label(audio.t(.recordTest), systemImage: "mic.fill")
            }
            .controlSize(.small)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AudioViewModel())
        .frame(width: 460, height: 520)
}
