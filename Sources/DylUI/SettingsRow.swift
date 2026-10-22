#if canImport(SwiftUI)
import SwiftUI

/// A Settings row: a tinted icon tile, a bold title over a subtitle, optional monospaced
/// tags in the palette's accent, and an optional round button that opens `link`. The tile uses `color`, or the
/// palette's accent without one.
public struct SettingsRow: View {
    @Environment(\.palette) private var palette
    @State private var isHovering = false
    private let title: String
    private let subtitle: String
    private let systemImage: String
    private let color: Color?
    private let tags: [String]
    private let link: URL?

    public init(
        _ title: String, subtitle: String, systemImage: String, color: Color? = nil, tags: [String] = [],
        link: URL? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.color = color
        self.tags = tags
        self.link = link
    }

    public var body: some View {
        let accent = palette?.accent ?? .accentColor
        HStack(spacing: 12) {
            iconTile(color ?? accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.monospaced().weight(.medium))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.10), in: .capsule)
                        .overlay(Capsule().strokeBorder(accent.opacity(0.22), lineWidth: 1))
                }
                if let link {
                    Link(destination: link) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.quaternary.opacity(isHovering ? 0.9 : 0.45)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(title)")
                }
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }

    @ViewBuilder
    private func iconTile(_ tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let tile = Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.14), in: shape)
        if #available(macOS 26, iOS 26, *) {
            tile.glassEffect(.regular.tint(tint.opacity(0.12)), in: shape)
        } else {
            tile
        }
    }
}
#endif
