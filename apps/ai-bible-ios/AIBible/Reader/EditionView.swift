import SwiftUI

/// The edition's cover and title page, shown natively from the converted source.
/// Everything is bundled, so it works offline. Text uses system styles for Dynamic Type.
struct EditionView: View {
    @Environment(AppModel.self) private var model
    let focus: EditionFocus
    @State private var didScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let cover = model.book.presentation?.cover {
                        coverView(cover)
                            .id(EditionFocus.cover)
                    }
                    if let titlePage = model.book.presentation?.titlePage {
                        TitlePageView(titlePage: titlePage)
                            .id(EditionFocus.titlePage)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                guard !didScroll else { return }
                didScroll = true
                proxy.scrollTo(focus, anchor: .top)
            }
        }
        .navigationTitle("Cover and title page")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func coverView(_ cover: CoverImage) -> some View {
        if let data = model.coverImage, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(verbatim: cover.alt))
                .accessibilityIdentifier("edition.cover")
        } else {
            // The loader refuses an edition whose cover is missing, so this only shows for malformed data.
            Label("Cover image unavailable", systemImage: "photo")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("edition.cover")
        }
    }
}

/// Title-page elements in source order, styled by their role.
struct TitlePageView: View {
    let titlePage: TitlePage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(titlePage.elements.enumerated()), id: \.offset) { index, element in
                Text(InlineText.attributed(element.text))
                    .font(Self.font(for: element.role))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(element.role == .title ? .isHeader : [])
                    .accessibilityIdentifier("edition.titlePage.\(index)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("edition.titlePage")
    }

    static func font(for role: TitlePageElement.Role) -> Font {
        switch role {
        case .title: return .largeTitle.weight(.bold)
        case .subtitle: return .title2
        case .author: return .title3
        case .paragraph: return .body
        }
    }
}
