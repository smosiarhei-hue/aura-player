import SwiftUI

struct AppIconPickerView: View {
    @State private var manager = AppIconManager.shared
    @State private var l10n = SonivoL10n.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                ForEach(SonivoAppIcon.allCases) { icon in
                    Button {
                        manager.select(icon, russian: l10n.isRussian)
                    } label: {
                        HStack(spacing: 16) {
                            AppIconThumbnail(icon: icon, size: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(icon.title(russian: l10n.isRussian))
                                    .foregroundStyle(SN.ink)
                                Text(icon.detail(russian: l10n.isRussian))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if manager.selected == icon {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(SN.ember)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isChanging || !manager.supportsAlternates)
                    .accessibilityLabel(icon.title(russian: l10n.isRussian))
                    .accessibilityValue(manager.selected == icon
                        ? (l10n.isRussian ? "Выбрано" : "Selected") : "")
                    .accessibilityAddTraits(manager.selected == icon ? .isSelected : [])
                }
                if manager.isChanging {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(l10n.isRussian ? "Меняем иконку…" : "Changing icon…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(l10n.isRussian ? "Иконка на домашнем экране" : "Home Screen icon")
            } footer: {
                Text(manager.supportsAlternates
                    ? (l10n.isRussian
                       ? "Выбор сохраняется системой iOS. Система может показать подтверждение. Свет, оттенок и объём зависят от оформления домашнего экрана; миниатюры здесь плоские."
                       : "iOS saves your selection and may show a confirmation. Home Screen appearance controls lighting, tint and depth; these thumbnails are flat.")
                    : (l10n.isRussian
                       ? "В этой установке приложения смена иконки недоступна."
                       : "This installation does not support alternate icons."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(SN.bg)
        .navigationTitle(l10n.isRussian ? "Иконка приложения" : "App icon")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.synchronize() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.synchronize() }
        }
        .alert(l10n.isRussian ? "Не удалось сменить иконку" : "Couldn't change icon",
               isPresented: Binding(
                   get: { manager.errorMessage != nil },
                   set: { if !$0 { manager.errorMessage = nil } }
               )) {
            Button("OK", role: .cancel) { manager.errorMessage = nil }
        } message: {
            Text(manager.errorMessage ?? "")
        }
    }
}

struct AppIconThumbnail: View {
    let icon: SonivoAppIcon
    var size: CGFloat = 44

    var body: some View {
        Image(icon.previewName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}