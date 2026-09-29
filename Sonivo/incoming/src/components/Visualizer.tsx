import { useEffect, useRef } from "react";
import type { AutoMixEngine } from "../audio/engine";

interface Props {
  engine: AutoMixEngine | null;
  color: string;
  color2: string;
  height?: number;
}

export default function Visualizer({ engine, color, color2, height = 72 }: Props) {
  const ref = useRef<HTMLCanvasElement>(null);
  const colorRef = useRef({ color, color2 });
  colorRef.current = { color, color2 };

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d")!;
    let raf = 0;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const resize = () => {
      const w = canvas.clientWidth;
      canvas.width = w * dpr;
      canvas.height = height * dpr;
    };
    resize();
    window.addEventListener("resize", resize);
    const smooth = new Float32Array(64);
    const draw = () => {
      raf = requestAnimationFrame(draw);
      const w = canvas.width, h = canvas.height;
      ctx.clearRect(0, 0, w, h);
      const bars = 48;
      const gap = 3 * dpr;
      const bw = (w - gap * (bars - 1)) / bars;
      const grad = ctx.createLinearGradient(0, h, 0, 0);
      grad.addColorStop(0, colorRef.current.color2);
      grad.addColorStop(1, colorRef.current.color);
      ctx.fillStyle = grad;
      const data = engine ? engine.spectrum() : null;
      for (let i = 0; i < bars; i++) {
        let v = 0;
        if (data) {
          // логарифмическое распределение частот
          const idx = Math.min(data.length - 1, Math.floor(Math.pow(i / bars, 1.7) * data.length * 0.8));
          v = data[idx] / 255;
        }
        smooth[i] += (v - smooth[i]) * 0.35;
        const bh = Math.max(2 * dpr, smooth[i] * h);
        const x = i * (bw + gap);
        const r = Math.min(bw / 2, 3 * dpr);
        ctx.beginPath();
        ctx.roundRect(x, h - bh, bw, bh, r);
        ctx.fill();
      }
    };
    draw();
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", resize);
    };
  }, [engine, height]);

  return <canvas ref={ref} className="w-full" style={{ height }} />;
}
