import SwiftUI

// MARK: - Интерактивная шторка настроек «Моей волны» (Apple Music & Liquid Glass)

struct WaveSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = WaveSettingsStore.shared
    @State private var player = ActivePlayerPresentation()
    @State private var isApplying = false
    @State private var applyStatusMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // 1. Характер звучания (Diversity)
                    diversitySection

                    // 2. Язык музыки (Language)
                    languageSection

                    // 3. Настроение и энергия (Mood)
                    moodSection

                    // Кнопка быстрого применения к текущей очереди
                    if player.isPlaying {
                        applyButton
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 40)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Настройка Моей волны")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                    .font(SN.text(.body, .bold))
                    .foregroundStyle(.white)
                }
            }
        }
        .presentationDetents([.fraction(0.88), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    // MARK: - 1. Характер звучания

    private var diversitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Характер музыки", subtitle: "Баланс знакомых хитов и новых открытий")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(WaveDiversity.allCases) { item in
                    let isSelected = settings.diversity == item
                    Button {
                        Haptics.tap(.light)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            settings.diversity = item
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(isSelected ? Color.black : Color.white)
                                .frame(width: 32, height: 32)
                                .background(
                                    Circle()
                                        .fill(isSelected ? Color.white : Color.white.opacity(0.12))
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(SN.text(.callout, .bold))
                                    .foregroundStyle(Color.white)
                                Text(item.subtitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.60))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.22) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(isSelected ? Color.white.opacity(0.65) : Color.white.opacity(0.10), lineWidth: isSelected ? 1.0 : 0.5)
                        )
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.96))
                }
            }
        }
    }

    // MARK: - 2. Язык

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Язык исполнения", subtitle: "Фильтрация треков по языку вокала")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(WaveLanguage.allCases) { item in
                        let isSelected = settings.language == item
                        Button {
                            Haptics.tap(.light)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                settings.language = item
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(item.title)
                                    .font(SN.text(.subheadline, isSelected ? .bold : .medium))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.07))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? Color.white.opacity(0.70) : Color.white.opacity(0.12), lineWidth: isSelected ? 1.0 : 0.5)
                            )
                        }
                        .buttonStyle(TactileButtonStyle(scale: 0.95))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - 3. Настроение

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Настроение", subtitle: "Энергетика и эмоциональная окраска")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(WaveMoodEnergy.allCases) { item in
                        let isSelected = settings.moodEnergy == item
                        Button {
                            Haptics.tap(.light)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                settings.moodEnergy = item
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(item.title)
                                    .font(SN.text(.subheadline, isSelected ? .bold : .medium))
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.07))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? Color.white.opacity(0.70) : Color.white.opacity(0.12), lineWidth: isSelected ? 1.0 : 0.5)
                            )
                        }
                        .buttonStyle(TactileButtonStyle(scale: 0.95))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Кнопка мгновенного применения к текущей волне

    private var applyButton: some View {
        VStack(spacing: 8) {
            Button {
                Haptics.tap(.medium)
                isApplying = true
                Task {
                    let success = await settings.reseedActiveWaveQueue()
                    await MainActor.run {
                        isApplying = false
                        applyStatusMessage = success ? "🌊 Очередь волны перестроена" : "Не удалось обновить очередь"
                    }
                    try? await Task.sleep(for: .seconds(2.5))
                    await MainActor.run {
                        applyStatusMessage = nil
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if isApplying {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .bold))
                        Text("Применить к текущей волне")
                            .font(SN.text(.body, .bold))
                    }
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .white.opacity(0.25), radius: 14, y: 3)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.97))
            .disabled(isApplying)

            if let msg = applyStatusMessage {
                Text(msg)
                    .font(SN.text(.caption, .semibold))
                    .foregroundStyle(Color.cyan)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Вспомогательный заголовок секции

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SN.text(.title3, .bold))
                .foregroundStyle(Color.white)
            Text(subtitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }
}
