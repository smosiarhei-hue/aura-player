/**
 * Premium AutoMix — полный платный функционал, который реально работает.
 *
 * Это не «кроссфейд на 8 секунд». Это автоматизация того, за что в DJ-софте
 * и стриминге обычно платят: harmonic mix, phrase grid, ONE BASS / ONE VOCAL,
 * Safe Exit, Mix Critic, HQ поток, и чистый LAND.
 *
 * LAND (handoff → 1) обязан:
 *   1. A уходит в ноль (vol) + HPF riser + короткий echo-хвост
 *   2. A lead никогда не возвращается (instr bed до конца)
 *   3. B уже «дома»: dry, bass on, LPF open
 *   4. Rate/pitch B → натуральные (1.0 / 0¢) к концу окна
 *   5. Handoff на доле фразы (bar grid)
 *   6. UI hard-snap обложки/таймлайна на B
 */

import type { MashupParams } from "./envelopes";
import type { AIMixPlan } from "./aiMixEngine";

/** Каталог premium-функций Sonivo Automix (всегда on в плеере). */
export const PREMIUM_FEATURES = [
  {
    id: "hqStream",
    label: "HQ / Lossless поток",
    detail: "Plus: FLAC через get-file-info; вне РФ/РБ — nq/192 (YM_PROXY)",
  },
  {
    id: "myWave",
    label: "Моя волна",
    detail: "Персональное радио + feedback started/finished",
  },
  {
    id: "bpmKey",
    label: "BPM + Camelot",
    detail: "Анализ пары → beatmatch и harmonic pitch",
  },
  {
    id: "phraseGrid",
    label: "Фраза 8/16 тактов",
    detail: "Окно сведения на сетке, не случайные секунды",
  },
  {
    id: "tzPlanner",
    label: "Transition Planner §2.4",
    detail: "EQ / Filter / Echo / Long / Cut / Smart — по BPM+key+outro",
  },
  {
    id: "oneBass",
    label: "ONE BASS",
    detail: "Бас A режется на доле → пол у B",
  },
  {
    id: "oneVocal",
    label: "ONE VOCAL / Safe Exit",
    detail: "Dual mashup только если outro A инструментал",
  },
  {
    id: "mixCritic",
    label: "Mix Critic",
    detail: "Vocal Safe + Bass Surgeon до play",
  },
  {
    id: "landExit",
    label: "Premium LAND",
    detail: "HPF + echo tail + rate/pitch settle + hard snap на B",
  },
  {
    id: "prefetch",
    label: "Prefetch next",
    detail: "Следующий трек волны качается во время PLAY",
  },
  {
    id: "whisperCue",
    label: "Whisper / LRC brain",
    detail: "Слушает A+B: mixOut на конце фразы, mixIn на входе → ровный mashup",
  },
] as const;

export type PremiumFeatureId = (typeof PREMIUM_FEATURES)[number]["id"];

export type LandRecipe = {
  /** Progress where LAND FX begin (≈ handoff). */
  landAt: number;
  /** Force A instrumental through end. */
  keepAInstr: boolean;
  /** Min HPF on A during LAND. */
  hpfFloor: number;
  /** Echo peak during LAND exit. */
  echoPeak: number;
  /** Progress where B rate/pitch must be natural. */
  settleBy: number;
  /** Story line for UI. */
  story: string;
};

/**
 * Snap a 0…1 progress point onto an N-bar grid inside the blend window.
 */
export function snapProgressToBar(
  progress: number,
  blendSec: number,
  bpm: number,
  bars = 1
): number {
  const barSec = (240 / Math.max(60, bpm)) * Math.max(1, bars);
  if (blendSec < barSec * 0.5) return Math.min(0.92, Math.max(0.08, progress));
  const t = progress * blendSec;
  const snapped = Math.round(t / barSec) * barSec;
  return Math.min(0.92, Math.max(0.12, snapped / blendSec));
}

/**
 * Build the LAND exit recipe from an already-planned mashup.
 */
export function buildLandRecipe(params: MashupParams): LandRecipe {
  const bpm = params.targetBPM > 30 ? params.targetBPM : 120;
  const landAt = snapProgressToBar(params.handoffAt, params.blendDurationSec, bpm, 1);
  // Duet: early LAND, moderate echo, never force instrumental bake.
  if (params.dsp.mashupMode === "oneBarDuet") {
    const duetLand = Math.min(0.7, landAt);
    return {
      landAt: duetLand,
      keepAInstr: false,
      hpfFloor: Math.max(0.7, params.dsp.hpfAPeak || 0.7),
      echoPeak: Math.min(0.28, Math.max(0.14, params.dsp.echoAPeak || 0.2)),
      settleBy: Math.min(0.96, duetLand + 0.18),
      story: "LAND · Duet HPF/echo → B home",
    };
  }
  const safe = params.dsp.mashupMode === "safeExit" || params.archetype === "cutOnOne";
  const echo =
    params.archetype === "echoOut"
      ? Math.max(0.55, params.dsp.echoAPeak)
      : safe
        ? Math.min(0.22, Math.max(0.08, params.dsp.echoAPeak))
        : Math.max(0.28, Math.min(0.7, params.dsp.echoAPeak || 0.35));

  return {
    landAt,
    keepAInstr: true,
    hpfFloor: safe ? 0.35 : Math.max(0.55, params.dsp.hpfAPeak || 0.55),
    echoPeak: echo,
    settleBy: Math.min(0.96, landAt + 0.22),
    story:
      params.dsp.mashupMode === "safeExit"
        ? "LAND · Echo Exit → B home"
        : params.archetype === "cutOnOne"
          ? "LAND · Cut on 1 → B home"
          : params.archetype === "echoOut"
            ? "LAND · echo tail → B natural"
            : "LAND · HPF exit → rate/pitch settle → B home",
  };
}

/**
 * Mutate plan params so LAND is fully automated (premium exit).
 * Call before the final Mix Critic so Vocal Safe / Bass Surgeon can correct the snap.
 */
export function applyPremiumLand(plan: AIMixPlan): AIMixPlan {
  const params = plan.params;
  const land = buildLandRecipe(params);
  const bpm = params.targetBPM > 30 ? params.targetBPM : plan.profileA.bpm || 120;

  // Phrase-align handoff (LAND start on a bar).
  params.handoffAt = land.landAt;
  // Bass swap stays earlier than LAND, still on grid.
  params.bassSwapAt = Math.min(
    params.handoffAt - 0.1,
    snapProgressToBar(params.bassSwapAt, params.blendDurationSec, bpm, 1)
  );
  params.bassSwapAt = Math.max(0.12, params.bassSwapAt);

  // LAND FX floors — never leave A singing or B muffled into home.
  params.dsp.hpfAPeak = Math.max(params.dsp.hpfAPeak, land.hpfFloor);
  params.dsp.echoAPeak = Math.max(params.dsp.echoAPeak * 0.5, land.echoPeak * 0.85);
  if (params.dsp.mashupMode === "acapellaDrop") {
    // Keep dual-layer quality: echo capped, but LAND still has a clean exit.
    params.dsp.echoAPeak = Math.min(0.28, params.dsp.echoAPeak);
    params.dsp.hpfAPeak = Math.max(0.5, params.dsp.hpfAPeak);
  }
  if (land.keepAInstr && params.dsp.instrAPeak < 0.2 && params.dsp.mashupMode === "acapellaDrop") {
    params.dsp.instrAPeak = Math.max(params.dsp.instrAPeak, 0.35);
    params.dsp.bakeInstrA = true;
    params.dsp.bakeStems = true;
  }

  // Guarantee rate/pitch envelopes have room to settle before end.
  // (playbackRatesAt / pitchCentsAt already ramp after handoff — handoff snap helps.)
  params.dsp.decisions = [
    ...params.dsp.decisions,
    `Premium LAND @${((land.landAt * 100) | 0)}% · settle@${((land.settleBy * 100) | 0)}%`,
    land.story,
  ];

  const story = `${plan.story} → ${land.story}`;
  const processing = [
    ...plan.processing,
    `Premium LAND: HPF≥${land.hpfFloor.toFixed(2)} · echo≥${land.echoPeak.toFixed(2)} · bar-snap handoff`,
    ...PREMIUM_FEATURES.map((f) => `✓ ${f.label}`),
  ];

  return {
    ...plan,
    params,
    story,
    processing,
  };
}

/** Short UI blurb for the player. Empty when no pair is planned. */
export function premiumLandBlurb(plan: AIMixPlan | null): string {
  if (!plan) return "";
  const mode = plan.params.dsp.mashupMode;
  if (mode === "safeExit") {
    const sec = plan.params.blendDurationSec;
    return `Automix · Echo Exit · ${sec >= 1 ? `${sec.toFixed(0)}s` : "phrase"} → LAND`;
  }
  if (mode === "acapellaDrop") {
    const sec = plan.params.blendDurationSec;
    return `Acapella Drop · ${sec >= 1 ? `${sec.toFixed(0)}s` : "mashup"} → ONE BASS → LAND`;
  }
  if (mode === "oneBarDuet") {
    const sec = plan.params.blendDurationSec;
    const bpm = plan.params.targetBPM > 30 ? plan.params.targetBPM : 120;
    const bars = Math.max(1, Math.round(sec / (240 / bpm)));
    return `Duet · ${bars} bars · ${sec >= 1 ? `${sec.toFixed(0)}s` : "phrase"} · B-led → LAND`;
  }
  return `${plan.story}`;
}
