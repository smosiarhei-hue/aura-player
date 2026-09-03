/// <reference lib="webworker" />
import { analyzeAudio } from "./analysisCore";

self.onmessage = (e: MessageEvent) => {
  const { id, samples, sampleRate, duration } = e.data as {
    id: string;
    samples: Float32Array;
    sampleRate: number;
    duration: number;
  };
  try {
    const result = analyzeAudio({ samples, sampleRate, duration });
    (self as unknown as Worker).postMessage({ id, ok: true, result });
  } catch (err) {
    (self as unknown as Worker).postMessage({ id, ok: false, error: String(err) });
  }
};
