import SwiftUI

/// A panel opened over the picture from a button in the player's controls.
enum PlayerPanel: Equatable {
    /// The videos of the queue that is playing.
    case queue
    /// The subtitle tracks, and Dual Subtitles.
    case subtitles
}

/// The subtitle tracks, in a panel over the picture rather than a menu.
///
/// A menu closes on every click, and picking Dual Subtitles is several in a
/// row: switching it on, then a track for ❶ and another for ❷. The panel stays
/// up through all of them, with each pick showing at once, until a click
/// anywhere else puts it away — as the list of the queue does.
///
/// Only what is a choice about the file being watched is here. The timing and
/// the size are settings, and stay in the Subtitles menu in the menu bar.
struct PlayerSubtitlePanel: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var state: PlayerState
    let onClose: () -> Void

    /// Read from the defaults so the panel follows the switch as it is flipped.
    @AppStorage(SubtitlePreference.dualKey) private var isDual = false

    private static let rowHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            ScrollView {
                VStack(spacing: 2) {
                    row(
                        title: "Off",
                        detail: nil,
                        mark: state.selectedSubtitleID == nil && state.secondarySubtitle == nil
                            ? .check : nil
                    ) {
                        appModel.selectSubtitle(nil)
                    }
                    if state.subtitles.isEmpty {
                        Text("No subtitles in this file")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 36)
                            .frame(height: Self.rowHeight)
                    } else {
                        ForEach(state.subtitles) { track in
                            trackRow(track)
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: listHeight)
            divider
            loadButton
        }
        .frame(width: 340)
        .playerPanel(cornerRadius: 14)
    }

    /// Tall enough for every track, up to a point.
    private var listHeight: CGFloat {
        let rows = CGFloat(min(max(state.subtitles.count, 1) + 1, 10))
        return 12 + rows * Self.rowHeight + (rows - 1) * 2
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 0.5)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Subtitles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            Toggle(isOn: Binding(
                get: { isDual },
                set: { _ in appModel.toggleDualSubtitles() }
            )) {
                Text("Dual Subtitles")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Show two subtitles at once, numbered in the order they are picked")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 44)
    }

    private var loadButton: some View {
        Button {
            // The open panel is a sheet on the window, and this panel would
            // otherwise sit over the picture behind it.
            onClose()
            SubtitleFile.choose { url in
                appModel.loadExternalSubtitle(url)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 12))
                    .frame(width: 20)
                Text("Load Subtitle…")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 6)
            .frame(height: Self.rowHeight)
            .playerHighlight()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
    }

    private func trackRow(_ track: SubtitleTrack) -> some View {
        let mark: RowMark?
        if isDual {
            // Two at once are numbered rather than checked, ❶ the subtitle
            // and ❷ the one beside it, in the order they were picked.
            mark = track.isSelected ? .number(1) : track.isSecondary ? .number(2) : nil
        } else {
            mark = track.isSelected ? .check : nil
        }
        return row(
            title: track.displayName(playing: state.currentURL),
            detail: track.isExternal ? "External" : nil,
            mark: mark
        ) {
            if isDual {
                appModel.pickDualSubtitle(track)
            } else {
                appModel.selectSubtitle(track)
            }
        }
        .help(track.externalURL?.lastPathComponent ?? track.displayName)
    }

    private enum RowMark: Equatable {
        case check
        case number(Int)

        var symbol: String {
            switch self {
            case .check: "checkmark"
            case .number(let number): "\(number).circle.fill"
            }
        }
    }

    private func row(
        title: String,
        detail: String?,
        mark: RowMark?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // A column of its own whether marked or not, so every title
                // starts at the same place.
                Color.clear
                    .frame(width: 20, height: 20)
                    .overlay {
                        if let mark {
                            Image(systemName: mark.symbol)
                                .font(.system(size: mark == .check ? 11 : 13, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }

                Text(title)
                    .font(.system(size: 13, weight: mark == nil ? .regular : .semibold))
                    .foregroundStyle(Color.white.opacity(mark == nil ? 0.8 : 1))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Self.rowHeight)
            .playerHighlight(isActive: mark != nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue(for: mark))
    }

    private func accessibilityValue(for mark: RowMark?) -> String {
        switch mark {
        case .check: "Selected"
        case .number(1): "First subtitle"
        case .number: "Second subtitle"
        case nil: ""
        }
    }
}
