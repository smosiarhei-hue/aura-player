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
  /** Моменты дропов / кульминаций (сек) */
  drops: number[];
  /** Моменты ям / брейкдаунов (сек) */
  breakdowns: number[];
  /** Моменты билдапов / разгонов (сек) */
  buildUps: number[];
  /** Секунда вступления вокала в интро */
  vocalStart?: number;
  /** Секунда окончания вокала перед аутро */
  vocalEnd?: number;
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

export type MixStyle = "mashup" | "smooth" | "club" | "echo" | "cut";

export interface MixSettings {
  style: MixStyle;
  /** длина перехода в битах (при ручном режиме) */
  lengthBeats: number;
  /** ИИ-автоподбор длины перехода (в тактах и долях) под структуру треков */
  autoLength: boolean;
  beatmatch: boolean;
  keyMatch: boolean;
  wave: boolean; // «Моя волна» — автоподбор
  eqSwap: boolean;
  autoGain: boolean;
  riserEffect: boolean; // Резонансный свип-райзер
  beatRoll: boolean; // Заикание/строб перед дропом
  smartCues: boolean; // ИИ подбор точек дропа/входа
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
  plannedBars: number;
  plannedBeats: number;
  currentBar: number;
  currentBeat: number;
  description?: string;
}

export interface WaveReason {
  label: string;
  ok: boolean;
}
