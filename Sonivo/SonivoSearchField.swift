import SwiftUI

/// Always-visible input: opening the Search tab does not require expanding a second bar.
struct SonivoSearchField: View {
    @Binding var text: String
    var isActive: Bool
    var prompt: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(SN.inkMuted).accessibilityHidden(true)
            TextField(prompt,text: $text)
                .font(SN.text(.body)).foregroundStyle(SN.ink)
                .focused($focused)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).onSubmit { onSubmit(); focused=false }
                .accessibilityLabel(prompt)
                .accessibilityIdentifier("sonivo.search.input")
            if !text.isEmpty {
                Button { text=""; focused=true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(SN.inkMuted)
                        .frame(width: 44,height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.leading,14).padding(.trailing,text.isEmpty ? 14 : 0)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 14).fill(SN.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SN.hairline,lineWidth: 0.5))
        .task(id: isActive) {
            guard isActive else { focused=false; return }
            // Wait only for the field to enter the view tree, not an arbitrary animation.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused=true
        }
    }
}
