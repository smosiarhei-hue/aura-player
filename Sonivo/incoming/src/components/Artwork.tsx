import type { Track } from "../types";
import { cn } from "../utils/cn";

const GLYPHS: Record<string, string> = {
  House: "◐",
  Techno: "▣",
  "Hip-Hop": "◆",
  Pop: "✦",
  "Drum & Bass": "◭",
  "Lo-Fi": "☾",
  Trance: "◎",
  Ambient: "≈",
  Rock: "▲",
  Unknown: "♪",
};

export default function Artwork({ track, className, size = "lg" }: { track: Track | null; className?: string; size?: "sm" | "lg" }) {
  const c1 = track?.color ?? "#6366f1";
  const c2 = track?.color2 ?? "#0f172a";
  const glyph = GLYPHS[track?.analysis?.genre ?? "Unknown"];
  return (
    <div
      className={cn("relative overflow-hidden rounded-2xl", className)}
      style={{ background: `radial-gradient(120% 120% at 20% 10%, ${c1} 0%, ${c2} 70%)` }}
    >
      <div
        className="absolute inset-0 opacity-40"
        style={{ background: `conic-gradient(from 200deg at 70% 80%, transparent 0deg, ${c1}66 90deg, transparent 180deg)` }}
      />
      <div className={cn("absolute inset-0 flex items-center justify-center text-white/80", size === "lg" ? "text-6xl" : "text-lg")}>
        <span style={{ textShadow: "0 4px 24px rgba(0,0,0,.4)" }}>{glyph}</span>
      </div>
      {size === "lg" && (
        <div className="absolute inset-x-0 bottom-0 h-1/3 bg-gradient-to-t from-black/40 to-transparent" />
      )}
    </div>
  );
}
