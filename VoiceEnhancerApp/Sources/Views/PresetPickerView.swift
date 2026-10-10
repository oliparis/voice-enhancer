import SwiftUI

/// A grid of four tappable preset cards.
///
/// Design notes:
///   * Cards are equally-weighted — we don't promote a "recommended" preset
///     at the UI level. If users wanted a default they'd leave it alone.
///   * The selected card is indicated with a colored ring, not a checkmark.
///     Rings scale better visually with our minimal card layout.
///   * Card tap animates the selection with a spring to give the feel of
///     directly manipulating the audio. Snappy, not bouncy.
struct PresetPickerView: View {
    @EnvironmentObject private var audio: AudioViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: audio.t(.preset))

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Preset.allCases.filter { $0.isFactoryPreset }) { preset in
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            audio.recallPreset(preset)
                        }
                    } label: {
                        PresetCardView(preset: preset, isSelected: audio.selectedPreset == preset,
                                       language: audio.appLanguage)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name(language: audio.appLanguage))
                    .accessibilityHint(preset.blurb(language: audio.appLanguage))
                }
            }
            Button { audio.recallPreset(.custom) } label: {
                Label(Preset.custom.name(language: audio.appLanguage), systemImage: Preset.custom.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(audio.selectedPreset == .custom ? .accentColor : .secondary)
            .accessibilityAddTraits(audio.selectedPreset == .custom ? .isSelected : [])
            .help(Preset.custom.blurb(language: audio.appLanguage))
            if let notice = audio.settingsRecoveryNotice {
                Text(notice.text(language: audio.appLanguage)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    PresetPickerView()
        .environmentObject(AudioViewModel())
        .padding()
        .frame(width: 560)
}
