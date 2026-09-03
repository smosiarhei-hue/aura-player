import type { TrackAnalysis } from "../types";
import { analyzeAudio } from "./analysisCore";
import AnalyzerWorker from "./analyzer.worker.ts?worker&inline";

let worker: Worker | null = null;
let workerBroken = false;
const pending = new Map<string, { resolve: (a: TrackAnalysis) => void; reject: (e: unknown) => void }>();

function failAll(err: unknown) {
  for (const p of pending.values()) p.reject(err);
  pending.clear();
}

function getWorker(): Worker | null {
  if (workerBroken) return null;
  if (worker) return worker;
  try {
    worker = new AnalyzerWorker();
    worker.onmessage = (e: MessageEvent) => {
      const { id, ok, result, error } = e.data;
      const p = pending.get(id);
      if (!p) return;
      pending.delete(id);
      ok ? p.resolve(result) : p.reject(error);
    };
    worker.onerror = (ev) => {
      workerBroken = true;
      worker = null;
      failAll(ev);
    };
  } catch {
    workerBroken = true;
    worker = null;
  }
  return worker;
}

/** Смешиваем каналы в моно и даунсемплим до ~22 кГц — быстрее, а точности хватает */
function toMono(buffer: AudioBuffer): { samples: Float32Array; sampleRate: number } {
  const ch = buffer.numberOfChannels;
  const factor = buffer.sampleRate >= 44100 ? 2 : 1;
  const len = Math.floor(buffer.length / factor);
  const out = new Float32Array(len);
  for (let c = 0; c < ch; c++) {
    const data = buffer.getChannelData(c);
    for (let i = 0; i < len; i++) out[i] += data[i * factor] / ch;
  }
  return { samples: out, sampleRate: buffer.sampleRate / factor };
}

export async function analyzeBuffer(id: string, buffer: AudioBuffer): Promise<TrackAnalysis> {
  const { samples, sampleRate } = toMono(buffer);
  const duration = buffer.duration;
  const w = getWorker();
  if (w) {
    try {
      // копируем, чтобы при сбое воркера данные остались для фолбэка
      const copy = samples.slice();
      return await new Promise<TrackAnalysis>((resolve, reject) => {
        pending.set(id, { resolve, reject });
        w.postMessage({ id, samples: copy, sampleRate, duration }, [copy.buffer]);
      });
    } catch (err) {
      console.warn("worker analysis failed, falling back to main thread", err);
    }
  }
  // Фолбэк: главный поток, но уступаем кадр UI перед тяжёлой работой
  await new Promise((r) => setTimeout(r, 0));
  return analyzeAudio({ samples, sampleRate, duration });
}
