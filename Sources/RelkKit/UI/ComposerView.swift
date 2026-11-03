import PhotosUI
import SwiftUI

struct ComposerView: View {
    @Bindable var store: ChatStore
    let screen: String?
    let meta: [String: RelkMetaValue]

    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.draftImages.isEmpty || store.preparingImageCount > 0 {
                DraftStrip(store: store)
            }
            HStack(alignment: .bottom, spacing: 8) {
                attachButton
                TextField(text: $store.draftText, prompt: Text("Message", bundle: .module), axis: .vertical) {
                    Text("Message", bundle: .module)
                }
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color(uiColor: .separator))
                }
                sendButton
            }
            if store.isDraftTooLong {
                Text("\(store.draftLength - ChatStore.maxBodyLength) characters over the limit", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 52)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            store.addImages(items.map { item in
                { @Sendable () async throws -> Data in
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw RelkError.imageUnreadable
                    }
                    return data
                }
            })
            pickerItems = []
        }
        .alert(Text("Couldn't attach the image", bundle: .module), isPresented: $store.attachmentFailed) {
            Button(role: .cancel) {} label: { Text("OK", bundle: .module) }
        }
    }

    private var attachButton: some View {
        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: max(1, store.remainingImageSlots),
            selectionBehavior: .ordered,
            matching: .images
        ) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3)
                .frame(width: 36, height: 36)
        }
        .disabled(store.remainingImageSlots == 0)
        .accessibilityLabel(Text("Attach screenshot", bundle: .module))
    }

    private var sendButton: some View {
        Button {
            store.send(screen: screen, meta: meta)
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 36, height: 36)
        }
        .disabled(!store.canSend)
        .accessibilityLabel(Text("Send", bundle: .module))
    }
}

private struct DraftStrip: View {
    let store: ChatStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(store.draftImages.enumerated()), id: \.element.id) { index, draft in
                    Image(uiImage: draft.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel(Text("Screenshot \(index + 1) of \(store.draftImages.count)", bundle: .module))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                store.removeDraftImage(draft.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.title3)
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel(Text("Remove screenshot", bundle: .module))
                        }
                }
                ForEach(0..<store.preparingImageCount, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 64, height: 64)
                        .overlay { ProgressView() }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 4)
        }
    }
}
