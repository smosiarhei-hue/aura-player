export type Genre =
  | "House"
  | "Techno"
  | "Hip-Hop"
  | "Pop"
  | "Drum & Bass"
  | "Lo-Fi"
  | "Trance"
  | "Ambient"
  | "Rock"
  | "Unknown";

export interface TrackAnalysis {
  bpm: number;
  /** Секунда первого бита (фаза сетки) */
  beatOffset: number;
  /** Средняя энергия 0..1 */
  energy: number;
  /** Яркость спектра 0..1 */
  brightness: number;
  /** Плотность ударных 0..1 */
  danceability: number;
  key: string; // например "A minor"
  camelot: string; // например "8A"
  /** Точка, где стоит начинать миксовать в трек */
  mixIn: number;
  /** Точка начала перехода наружу */
  mixOut: number;
  genre: Genre;
  loudnessDb: number;
  /** Волновая форма для UI (0..1) */
  waveform: number[];
}

export interface Track {
  id: string;
  title: string;
  artist: string;
  duration: number;
  source: "file" | "demo";
  buffer: AudioBuffer | null;
  analysis: TrackAnalysis | null;
  analyzing: boolean;
  color: string;
  color2: string;
}

export type MixStyle = "smooth" | "club" | "cut" | "echo";

export interface MixSettings {
  style: MixStyle;
  /** длина перехода в битах */
  lengthBeats: number;
  beatmatch: boolean;
  keyMatch: boolean;
  wave: boolean; // «Моя волна» — автоподбор
  eqSwap: boolean;
  autoGain: boolean;
}

export interface TransitionState {
  active: boolean;
  fromId: string | null;
  toId: string | null;
  progress: number; // 0..1
  startedAt: number;
  duration: number;
  tempoShift: number; // %
  style: MixStyle;
}

export interface WaveReason {
  label: string;
  ok: boolean;
}
