// Path: Sonivo/DJAutoMixEngine/DJAutoMixCoordinator.swift
import Foundation
import AVFoundation

nonisolated public enum PreparedTransition: @unchecked Sendable {
    case hardCut
    case simpleCrossfade(duration: TimeInterval)
    case offlineRenderedMix(plan: DJMixPlan, buffer: AVAudioPCMBuffer)
}

@MainActor
public final class DJAutoMixCoordinator {
    public static let shared = DJAutoMixCoordinator()

    public let analyzer: any DJTrackAnalyzer
    public let planner: any DJTransitionPlanner
    public let syncEngine: any DJSyncEngine
    public let renderer: any DJMixRenderer

    public init(
        analyzer: any DJTrackAnalyzer = AudioTrackAnalyzer(),
        planner: any DJTransitionPlanner = DefaultDJTransitionPlanner(),
        syncEngine: any DJSyncEngine = DefaultDJSyncEngine(),
        renderer: any DJMixRenderer = DefaultDJMixRenderer()
    ) {
        self.analyzer = analyzer
        self.planner = planner
        self.syncEngine = syncEngine
        self.renderer = renderer
    }

    /// Сквозной пайплайн подготовки перехода (п. 7 ТЗ):
    /// 1. Анализ обоих треков (через кеш).
    /// 2. Планирование типа перехода (djStyleMix / simpleCrossfade / hardCut).
    /// 3. Для djStyleMix — фазовое выравнивание и тайм-стретчинг входящего буфера.
    /// 4. Офлайн-рендеринг готового переходного PCM-буфера.
    /// 5. При любой ошибке/нехватке данных — безопасный фоллбэк без крашей и тишины.
    public func prepareTransition(
        outgoingURL: URL,
        incomingURL: URL,
        outgoingBuffer: AVAudioPCMBuffer?,
        incomingBuffer: AVAudioPCMBuffer?
    ) async -> PreparedTransition {
        do {
            // Шаг 1: Анализ обоих треков
            async let outAnalysisTask = analyzer.analyze(outgoingURL)
            async let inAnalysisTask = analyzer.analyze(incomingURL)
            let (outAnalysis, inAnalysis) = try await (outAnalysisTask, inAnalysisTask)

            // Шаг 2: Планирование перехода
            let transitionType = planner.plan(outgoing: outAnalysis, incoming: inAnalysis)

            switch transitionType {
            case .hardCut:
                return .hardCut

            case .simpleCrossfade(let duration):
                return .simpleCrossfade(duration: duration)

            case .djStyleMix(let plan):
                // Шаг 3 & 4: Офлайн-рендеринг буфера перехода
                guard let outgoingBuffer, let incomingBuffer else {
                    // Если PCM-буферы недоступны (напр. чистый стриминг без скачанного файла) — фоллбэк на кроссфейд
                    return .simpleCrossfade(duration: min(plan.duration, 4.0))
                }

                // Выравнивание темпа и фазы сетки
                let (alignedBuffer, _) = try syncEngine.align(
                    incoming: incomingBuffer,
                    plan: plan,
                    analysis: inAnalysis
                )

                // Офлайн-рендер стыка
                let renderedMix = try await renderer.renderTransition(
                    plan: plan,
                    outgoing: outgoingBuffer,
                    incoming: alignedBuffer
                )

                return .offlineRenderedMix(plan: plan, buffer: renderedMix)
            }
        } catch {
            // Шаг 6: Фоллбэк при любых ошибках
            return .simpleCrossfade(duration: 4.0)
        }
    }
}
