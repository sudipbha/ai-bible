import SwiftUI

/// Renders one content block with system text styles, so Dynamic Type, Bold Text
/// and VoiceOver work without extra settings.
struct BlockView: View {
    let block: Block

    var body: some View {
        switch block.kind {
        case .heading:
            Text(InlineText.attributed(block.text ?? ""))
                .font(block.level == 3 ? .title3.weight(.semibold) : .title2.weight(.semibold))
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            Text(InlineText.attributed(block.text ?? ""))
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .list:
            ListBlockView(items: block.items ?? [])
        case .checklist:
            ChecklistBlockView(items: block.items ?? [])
        case .table:
            if let table = block.table {
                TableBlockView(table: table)
            }
        case .note:
            NoteBlockView(text: block.text ?? "")
        }
    }
}

private struct ListBlockView: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("•").accessibilityHidden(true)
                    Text(InlineText.attributed(item))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A checklist printed in the book. Ticking items belongs in the Rollout tracker,
/// so these are static and read as list items.
private struct ChecklistBlockView: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "square")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(InlineText.attributed(item))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Checklist item: \(InlineText.plain(item))"))
            }
        }
    }
}

/// Tables use a grid at normal sizes and stacked "header: value" cards at
/// accessibility text sizes or when there are too many columns for a phone.
private struct TableBlockView: View {
    let table: TableData
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var useCards: Bool {
        typeSize.isAccessibilitySize || (sizeClass == .compact && table.header.count > 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let caption = table.caption {
                Text(InlineText.attributed(caption))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            if useCards { cards } else { grid }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(table.rows.indices, id: \.self) { row in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(table.header.indices, id: \.self) { column in
                        (Text("\(InlineText.plain(table.header[column])): ").bold()
                            + Text(InlineText.attributed(table.cell(row: row, column: column))))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(uiColor: .separator)))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    Text(InlineText.attributed(table.header[column]))
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Divider()
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        let value = table.cell(row: row, column: column)
                        Text(InlineText.attributed(value))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text("\(InlineText.plain(table.header[column])): \(InlineText.plain(value))"))
                    }
                }
            }
        }
    }
}

private struct NoteBlockView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Source note", systemImage: "text.quote")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(InlineText.attributed(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
