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
            ListBlockView(items: block.items ?? [], firstNumber: block.isOrderedList ? (block.start ?? 1) : nil)
        case .checklist:
            ChecklistBlockView(items: block.items ?? [])
        case .table:
            if let table = block.table {
                TableBlockView(table: table)
            }
        case .note:
            NoteBlockView(text: block.text ?? "")
        case .quote:
            QuoteBlockView(paragraphs: block.paragraphs ?? [])
        case .divider:
            Divider()
                .padding(.vertical, 8)
                .accessibilityElement()
                .accessibilityLabel(Text("Section break"))
        case .cards:
            if let group = block.cards {
                CardGroupView(group: group)
            }
        }
    }
}

/// Bulleted, or numbered from `firstNumber` (an ordered list can start at 4).
private struct ListBlockView: View {
    let items: [String]
    let firstNumber: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let firstNumber {
                        // Overflow-safe even for malformed data, which the loader rejects anyway.
                        let numbered = firstNumber.addingReportingOverflow(index)
                        Text(verbatim: numbered.overflow ? "•" : "\(numbered.partialValue).")
                            .monospacedDigit()
                    } else {
                        Text("•").accessibilityHidden(true)
                    }
                    Text(InlineText.attributed(item))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct QuoteBlockView: View {
    let paragraphs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(InlineText.attributed(paragraph))
                    .font(.body)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: 3)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Quotation"))
    }
}

/// Cards keep their own fields in source order; they are never merged into shared columns.
private struct CardGroupView: View {
    let group: CardGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let label = group.label {
                Text(InlineText.attributed(label))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(group.cards.enumerated()), id: \.offset) { _, card in
                CardView(card: card)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ifPresent: group.accessibilityLabel)
    }
}

private struct CardView: View {
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(card.fields.enumerated()), id: \.offset) { _, field in
                CardFieldView(field: field)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(uiColor: .separator)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ifPresent: card.accessibilityLabel)
    }
}

private struct CardFieldView: View {
    let field: CardField

    var body: some View {
        if let title = field.title {
            VStack(alignment: .leading, spacing: 2) {
                label
                Text(InlineText.attributed(title))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                label
                valueText(field.value ?? [])
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Blanks are read as what belongs there, not as underscores.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(InlineText.plain(field.label)): \(CardValuePart.spokenText(field.value ?? []))"))
        }
    }

    private var label: some View {
        Text(InlineText.attributed(field.label))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueText(_ parts: [CardValuePart]) -> Text {
        parts.reduce(Text(verbatim: "")) { result, part in
            if let text = part.text {
                return result + Text(InlineText.attributed(text))
            }
            if let blank = part.blank {
                return result + Text(verbatim: blank.text)
            }
            return result
        }
    }
}

private extension View {
    @ViewBuilder
    func accessibilityLabel(ifPresent label: String?) -> some View {
        if let label {
            accessibilityLabel(Text(label))
        } else {
            self
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
