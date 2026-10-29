import "./style.css";
import { AutomixEngine } from "./audio/engine";
import { analyzeTrackBuffer, type TrackAIProfile } from "./audio/analyzeTrack";
import { planAutomix } from "./audio/aiMixEngine";
import { defaultParams, tempoMatch } from "./audio/envelopes";
import type { MashupParams } from "./audio/envelopes";
import { transitionTypeLabel } from "./audio/transitionPlanner";
import { processBufferStem } from "./dsp/vocalInstrumental";

const params = defaultParams();
const engine = new AutomixEngine(params);
const profiles: { a: TrackAIProfile | null; b: TrackAIProfile | null } = {
  a: null,
  b: null,
};

const app = document.querySelector<HTMLDivElement>("#app")!;
app.innerHTML = `
  <header class="hero">
    <h1>Automix <span>Lab</span></h1>
    <p>
      По ТЗ AutoMix: анализ BPM + Key/Camelot → Transition Planner §2.4
      (EQ Blend / Filter Sweep / Echo Out / Long Blend / Cut / Smart Crossfade)
      → bake стемов → LOCK→LAND. Один клик <strong>AI Auto Mix</strong>.
    </p>
    <p class="hint" style="margin-top:8px">
      <a href="/iphone.html" style="color:var(--accent);font-weight:700">iPhone 17 Pro макет Sonivo →</a>
      плеер, Automix-инструменты и ручная настройка как в приложении.
    </p>
  </header>

  <div class="grid">
    <section class="panel">
      <h2>Деки</h2>
      <div class="decks">
        <div class="deck a">
          <div class="label">Deck A · outgoing</div>
          <label class="file-btn">Загрузить трек A
            <input id="fileA" type="file" accept="audio/*,.mp3,.wav,.m4a,.flac,.ogg" />
          </label>
          <div class="meta" id="metaA">файл не выбран</div>
          <div class="controls" style="margin-top:10px">
            <div class="row">
              <label>BPM A</label>
              <input id="bpmA" type="number" min="40" max="220" step="0.1" value="120" />
              <output></output>
            </div>
            <div class="row">
              <label>Cue A (сек)</label>
              <input id="cueA" type="range" min="0" max="300" step="0.1" value="0" />
              <output id="cueAOut">0.0</output>
            </div>
          </div>
          <div class="actions">
            <button class="ghost" id="soloA" type="button">Solo A от cue</button>
            <button class="ghost" id="analyzeA" type="button">AI анализ A</button>
          </div>
        </div>
        <div class="deck b">
          <div class="label">Deck B · incoming</div>
          <label class="file-btn">Загрузить трек B
            <input id="fileB" type="file" accept="audio/*,.mp3,.wav,.m4a,.flac,.ogg" />
          </label>
          <div class="meta" id="metaB">файл не выбран</div>
          <div class="controls" style="margin-top:10px">
            <div class="row">
              <label>BPM B</label>
              <input id="bpmB" type="number" min="40" max="220" step="0.1" value="124" />
              <output></output>
            </div>
            <div class="row">
              <label>Cue B (сек)</label>
              <input id="cueB" type="range" min="0" max="300" step="0.1" value="0" />
              <output id="cueBOut">0.0</output>
            </div>
          </div>
          <div class="actions">
            <button class="ghost" id="soloB" type="button">Solo B от cue</button>
            <button class="ghost" id="analyzeB" type="button">AI анализ B</button>
          </div>
        </div>
      </div>

      <div class="actions" style="margin-top:12px">
        <button class="ghost" id="loadSamples" type="button">Загрузить demo Midnight→Neon</button>
        <button class="ghost" id="loadRealPair" type="button">Загрузить nkeeei→Kai Angel</button>
      </div>

      <div class="transport">
        <div class="timeline"><div class="fill" id="fill"></div></div>
        <div class="times">
          <span id="timeLeft">0:00</span>
          <span class="mixing" id="mixing">Автомикс</span>
          <span id="timeRight">-0:00</span>
        </div>
        <div class="phase" id="phase">READY</div>
        <div class="tz-badge" id="tzBadge">TZ · —</div>
        <div class="ai-status" id="aiStatus">Загрузи A и B → нажми AI Auto Mix</div>
        <div class="meters">
          <div>
            <label>Vol A / Bass A</label>
            <div class="bar a"><i id="volA"></i></div>
            <div class="bar a" style="margin-top:4px"><i id="bassA"></i></div>
          </div>
          <div>
            <label>Vol B / Bass B</label>
            <div class="bar b"><i id="volB"></i></div>
            <div class="bar b" style="margin-top:4px"><i id="bassB"></i></div>
          </div>
        </div>
        <div class="meters dsp-meters">
          <div>
            <label>DSP A · instr / HPF / echo</label>
            <div class="bar a"><i id="instrA"></i></div>
            <div class="bar a" style="margin-top:4px"><i id="hpfA"></i></div>
            <div class="bar a" style="margin-top:4px"><i id="echoA"></i></div>
          </div>
          <div>
            <label>DSP B · instr→vocal / LPF</label>
            <div class="bar b"><i id="instrB"></i></div>
            <div class="bar b" style="margin-top:4px"><i id="vocalB"></i></div>
            <div class="bar b" style="margin-top:4px"><i id="lpfB"></i></div>
          </div>
        </div>
        <div class="actions">
          <button class="primary ai" id="aiAuto" type="button">✦ AI Auto Mix</button>
          <button class="primary" id="play" type="button">▶ Play mashup</button>
          <button class="warn" id="stop" type="button">Stop</button>
          <button class="ghost" id="matchTempo" type="button">Match BPM → rates</button>
        </div>
        <div class="error" id="error"></div>
        <p class="hint">
          <strong>AI Auto Mix</strong>: Key + BPM → тип перехода по §2.4, затем bake стемов,
          bass swap / filter / echo / cut. Ручки справа — только override.
        </p>
        <ul class="dsp-list" id="processingList" style="margin-top:10px"></ul>
      </div>
    </section>

    <section class="panel">
      <h2>Ручная настройка</h2>
      <div class="controls" id="knobs"></div>
      <div class="actions">
        <button class="ghost" id="exportBtn" type="button">Export JSON</button>
        <button class="ghost" id="importBtn" type="button">Import JSON</button>
        <button class="ghost" id="resetBtn" type="button">Reset</button>
      </div>
      <textarea class="preset-box" id="preset" spellcheck="false" placeholder="Пресет / AI plan появится здесь…"></textarea>
      <p class="hint">
        Алгоритм ≈ iOS <code>TrackAnalyzer</code> + <code>MashupLiveStyle.resolve</code>.
        DSP toolkit: <code>src/dsp/</code> — MidSideStem, BassEq, FilterSweep, EchoOut.
      </p>

      <h2 style="margin-top:22px">DSP инструменты</h2>
      <ul class="dsp-list">
        <li><strong>Mid/Side stem</strong> — A instrumentalize (вокал уходит), B vocalize</li>
        <li><strong>Bass EQ</strong> — ONE BASS: kill A lows, restore B + mid vocal pocket</li>
        <li><strong>HPF / LPF</strong> — HPF riser на A (LAND), LPF reveal на B (INVITE)</li>
        <li><strong>Echo-out</strong> — tempo-sync delay на хвосте A поверх B</li>
      </ul>
      <div class="actions">
        <button class="ghost" id="previewInstrA" type="button">Preview A instrumental</button>
        <button class="ghost" id="previewVocalB" type="button">Preview B vocal</button>
      </div>
    </section>
  </div>
`;

type Knob = {
  key: keyof MashupParams;
  label: string;
  min: number;
  max: number;
  step: number;
  format?: (v: number) => string;
};

const knobs: Knob[] = [
  { key: "blendDurationSec", label: "Окно сведения (сек)", min: 4, max: 40, step: 0.5 },
  { key: "rateA", label: "Rate A", min: 0.84, max: 1.16, step: 0.001, format: (v) => v.toFixed(3) },
  { key: "rateB", label: "Rate B", min: 0.84, max: 1.16, step: 0.001, format: (v) => v.toFixed(3) },
  { key: "pitchCentsB", label: "Pitch B (¢)", min: -200, max: 200, step: 1, format: (v) => `${v | 0}` },
  { key: "bassSwapAt", label: "Bass lock at", min: 0.05, max: 0.7, step: 0.01, format: (v) => v.toFixed(2) },
  { key: "handoffAt", label: "Handoff at", min: 0.2, max: 0.85, step: 0.01, format: (v) => v.toFixed(2) },
  { key: "outgoingVolumeHold", label: "A volume hold", min: 0.15, max: 0.7, step: 0.01, format: (v) => v.toFixed(2) },
  { key: "incomingVolumeLag", label: "B volume lag", min: 0.02, max: 0.4, step: 0.01, format: (v) => v.toFixed(2) },
  { key: "bassDepth", label: "Bass depth", min: 0.4, max: 1.6, step: 0.05, format: (v) => v.toFixed(2) },
];

const knobsEl = document.querySelector("#knobs")!;
for (const k of knobs) {
  const row = document.createElement("div");
  row.className = "row";
  row.innerHTML = `
    <label for="k-${k.key}">${k.label}</label>
    <input id="k-${k.key}" type="range" min="${k.min}" max="${k.max}" step="${k.step}" value="${params[k.key]}" />
    <output id="o-${k.key}"></output>
  `;
  knobsEl.appendChild(row);
}

function fmtTime(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) sec = 0;
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function setAiStatus(msg: string) {
  document.querySelector("#aiStatus")!.textContent = msg;
}

function setParamNumber(key: keyof MashupParams, value: number) {
  switch (key) {
    case "bassSwapAt":
    case "handoffAt":
    case "outgoingVolumeHold":
    case "incomingVolumeLag":
    case "bassDepth":
    case "rateA":
    case "rateB":
    case "pitchCentsB":
    case "targetBPM":
    case "blendDurationSec":
    case "cueASec":
    case "cueBSec":
      params[key] = value;
      break;
    default:
      break;
  }
}

function showProcessing(lines: string[]) {
  const el = document.querySelector("#processingList");
  if (!el) return;
  el.innerHTML = lines.map((l) => `<li>${l}</li>`).join("");
}

function applyParamsToUI(p: MashupParams, bpmA?: number, bpmB?: number) {
  Object.assign(params, p);
  for (const k of knobs) {
    const el = document.querySelector<HTMLInputElement>(`#k-${k.key}`);
    if (el) el.value = String(params[k.key]);
  }
  document.querySelector<HTMLInputElement>("#cueA")!.value = String(params.cueASec);
  document.querySelector<HTMLInputElement>("#cueB")!.value = String(params.cueBSec);
  if (bpmA != null) document.querySelector<HTMLInputElement>("#bpmA")!.value = String(bpmA);
  if (bpmB != null) document.querySelector<HTMLInputElement>("#bpmB")!.value = String(bpmB);
  syncKnobOutputs();
}

function syncKnobOutputs() {
  const dspKeep = params.dsp;
  for (const k of knobs) {
    const input = document.querySelector<HTMLInputElement>(`#k-${k.key}`)!;
    const out = document.querySelector<HTMLOutputElement>(`#o-${k.key}`)!;
    const v = Number(input.value);
    setParamNumber(k.key, v);
    out.textContent = k.format ? k.format(v) : String(v);
  }
  params.cueASec = Number(document.querySelector<HTMLInputElement>("#cueA")!.value);
  params.cueBSec = Number(document.querySelector<HTMLInputElement>("#cueB")!.value);
  params.dsp = dspKeep;
  document.querySelector("#cueAOut")!.textContent = params.cueASec.toFixed(1);
  document.querySelector("#cueBOut")!.textContent = params.cueBSec.toFixed(1);
  engine.setBpm("a", Number(document.querySelector<HTMLInputElement>("#bpmA")!.value));
  engine.setBpm("b", Number(document.querySelector<HTMLInputElement>("#bpmB")!.value));
  engine.setParams(params);
}

function wireKnobs() {
  for (const k of knobs) {
    document.querySelector(`#k-${k.key}`)?.addEventListener("input", syncKnobOutputs);
  }
  for (const id of ["cueA", "cueB", "bpmA", "bpmB"]) {
    document.querySelector(`#${id}`)?.addEventListener("input", syncKnobOutputs);
  }
}

function setCueMax(id: "a" | "b", duration: number) {
  const el = document.querySelector<HTMLInputElement>(id === "a" ? "#cueA" : "#cueB")!;
  el.max = String(Math.max(0, duration - 1));
  if (Number(el.value) > duration - 1) el.value = String(Math.max(0, duration * 0.75));
}

async function analyzeDeck(id: "a" | "b") {
  const deck = engine.getDeck(id);
  if (!deck.buffer) throw new Error(`Сначала загрузи трек ${id.toUpperCase()}`);
  const profile = await analyzeTrackBuffer(deck.buffer, deck.name, (msg) => {
    setAiStatus(`AI · ${id.toUpperCase()}: ${msg}`);
  });
  profiles[id] = profile;
  engine.setBpm(id, profile.bpm);
  document.querySelector<HTMLInputElement>(id === "a" ? "#bpmA" : "#bpmB")!.value = String(profile.bpm);
  setCueMax(id, profile.durationSec);
  const cueEl = document.querySelector<HTMLInputElement>(id === "a" ? "#cueA" : "#cueB")!;
  cueEl.value = String(id === "a" ? profile.mixOutSec : profile.mixInSec);
  const meta = document.querySelector(id === "a" ? "#metaA" : "#metaB")!;
  const key = profile.camelotKey
    ? `<span class="key-pill">${profile.camelotKey}</span>`
    : `<span class="key-pill dim">Key?</span>`;
  meta.innerHTML = `<strong>${profile.name}</strong> ${key}<br>${profile.durationSec.toFixed(1)}s · AI ${profile.reason}`;
  syncKnobOutputs();
  setAiStatus(`AI · ${id.toUpperCase()} готов: ${profile.reason}`);
  return profile;
}

async function onFile(id: "a" | "b", file: File | undefined) {
  const err = document.querySelector("#error")!;
  err.textContent = "";
  if (!file) return;
  try {
    setAiStatus(`Загрузка ${id.toUpperCase()}…`);
    const deck = await engine.loadFile(id, file);
    const meta = document.querySelector(id === "a" ? "#metaA" : "#metaB")!;
    meta.innerHTML = `<strong>${deck.name}</strong><br>${deck.duration.toFixed(1)}s · анализ…`;
    setCueMax(id, deck.duration);
    await analyzeDeck(id);
  } catch (e) {
    err.textContent = e instanceof Error ? e.message : String(e);
    setAiStatus("Ошибка анализа");
  }
}

function runPlanFromProfiles() {
  if (!profiles.a || !profiles.b) {
    throw new Error("Нужен AI-анализ обоих треков");
  }
  const plan = planAutomix(profiles.a, profiles.b);
  // Keep AI dsp recipe intact while syncing numeric knobs.
  const dsp = plan.params.dsp;
  applyParamsToUI(plan.params, plan.profileA.bpm, plan.profileB.bpm);
  params.dsp = dsp;
  engine.setParams(params);
  showProcessing(plan.processing);
  const tz = document.querySelector("#tzBadge");
  if (tz) {
    const keyLine = `${plan.profileA.camelotKey ?? "?"} → ${plan.profileB.camelotKey ?? "?"}`;
    tz.textContent = `TZ · ${transitionTypeLabel(plan.transitionType)} · ${keyLine}`;
    tz.setAttribute("data-type", plan.transitionType);
  }
  const box = document.querySelector<HTMLTextAreaElement>("#preset")!;
  box.value = JSON.stringify(
    {
      engine: "AutomixAI",
      tzSection: "2.4",
      transitionType: plan.transitionType,
      reason: plan.reason,
      story: plan.story,
      archetype: plan.archetype,
      beatmatched: plan.beatmatched,
      processing: plan.processing,
      dsp: plan.params.dsp,
      params: plan.params,
      profileA: {
        name: plan.profileA.name,
        bpm: plan.profileA.bpm,
        camelotKey: plan.profileA.camelotKey,
        keyConfidence: plan.profileA.keyConfidence,
        mixIn: plan.profileA.mixInSec,
        mixOut: plan.profileA.mixOutSec,
        confidence: plan.profileA.bpmConfidence,
      },
      profileB: {
        name: plan.profileB.name,
        bpm: plan.profileB.bpm,
        camelotKey: plan.profileB.camelotKey,
        keyConfidence: plan.profileB.keyConfidence,
        mixIn: plan.profileB.mixInSec,
        mixOut: plan.profileB.mixOutSec,
        confidence: plan.profileB.bpmConfidence,
      },
    },
    null,
    2
  );
  setAiStatus(plan.reason);
  document.querySelector("#phase")!.textContent = plan.beatmatched
    ? `AI LOCK ${Math.round(plan.params.targetBPM)}`
    : `AI ${transitionTypeLabel(plan.transitionType)}`;
  return plan;
}

document.querySelector("#fileA")?.addEventListener("change", (e) => {
  const f = (e.target as HTMLInputElement).files?.[0];
  void onFile("a", f);
});
document.querySelector("#fileB")?.addEventListener("change", (e) => {
  const f = (e.target as HTMLInputElement).files?.[0];
  void onFile("b", f);
});

async function loadUrlPair(urlA: string, urlB: string, nameA: string, nameB: string) {
  const err = document.querySelector("#error")!;
  err.textContent = "";
  setAiStatus(`Загрузка ${nameA} / ${nameB}…`);
  const [ra, rb] = await Promise.all([fetch(urlA), fetch(urlB)]);
  if (!ra.ok || !rb.ok) throw new Error("Не удалось скачать samples");
  const [ba, bb] = await Promise.all([ra.arrayBuffer(), rb.arrayBuffer()]);
  const fa = new File([ba], `${nameA}.wav`, { type: "audio/wav" });
  const fb = new File([bb], `${nameB}.wav`, { type: "audio/wav" });
  await onFile("a", fa);
  await onFile("b", fb);
}

document.querySelector("#loadSamples")?.addEventListener("click", () => {
  void loadUrlPair(
    "/samples/track-a-midnight.wav",
    "/samples/track-b-neon.wav",
    "midnight",
    "neon"
  ).catch((e) => {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
  });
});
document.querySelector("#loadRealPair")?.addEventListener("click", () => {
  void loadUrlPair(
    "/samples/track-a-nkeeei.wav",
    "/samples/track-b-kai-angel.wav",
    "nkeeei",
    "kai-angel"
  ).catch((e) => {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
  });
});

document.querySelector("#analyzeA")?.addEventListener("click", () => {
  void analyzeDeck("a").catch((e) => {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
  });
});
document.querySelector("#analyzeB")?.addEventListener("click", () => {
  void analyzeDeck("b").catch((e) => {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
  });
});

document.querySelector("#aiAuto")?.addEventListener("click", async () => {
  const err = document.querySelector("#error")!;
  const btn = document.querySelector<HTMLButtonElement>("#aiAuto")!;
  err.textContent = "";
  btn.disabled = true;
  try {
    if (!engine.getDeck("a").buffer || !engine.getDeck("b").buffer) {
      throw new Error("Загрузи оба трека");
    }
    setAiStatus("1/4 · анализ A…");
    if (!profiles.a) await analyzeDeck("a");
    setAiStatus("2/4 · анализ B…");
    if (!profiles.b) await analyzeDeck("b");
    setAiStatus("3/4 · план обработки (стемы / FX / cues)…");
    const plan = runPlanFromProfiles();
    setAiStatus(`4/4 · ${plan.story}`);
    await engine.playAutoMashup((msg) => setAiStatus(msg));
    setAiStatus(`Играю · ${plan.processing.slice(0, 2).join(" · ")}`);
    document.querySelector("#mixing")!.classList.add("on");
  } catch (e) {
    err.textContent = e instanceof Error ? e.message : String(e);
  } finally {
    btn.disabled = false;
  }
});

document.querySelector("#play")?.addEventListener("click", async () => {
  const err = document.querySelector("#error")!;
  err.textContent = "";
  syncKnobOutputs();
  try {
    await engine.playAutoMashup((msg) => setAiStatus(msg));
    document.querySelector("#mixing")!.classList.add("on");
  } catch (e) {
    err.textContent = e instanceof Error ? e.message : String(e);
  }
});

document.querySelector("#stop")?.addEventListener("click", () => {
  engine.stop();
  document.querySelector("#mixing")!.classList.remove("on");
  document.querySelector("#phase")!.textContent = "STOPPED";
});

document.querySelector("#soloA")?.addEventListener("click", async () => {
  syncKnobOutputs();
  try {
    await engine.playSolo("a");
    document.querySelector("#mixing")!.classList.remove("on");
  } catch (e) {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
  }
});

document.querySelector("#soloB")?.addEventListener("click", async () => {
  syncKnobOutputs();
  try {
    await engine.playSolo("b");
    document.querySelector("#mixing")!.classList.remove("on");
  } catch (e) {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
  }
});

document.querySelector("#matchTempo")?.addEventListener("click", () => {
  const bpmA = Number(document.querySelector<HTMLInputElement>("#bpmA")!.value);
  const bpmB = Number(document.querySelector<HTMLInputElement>("#bpmB")!.value);
  const match = tempoMatch(bpmA, bpmB);
  const err = document.querySelector("#error")!;
  if (!match) {
    err.textContent = "BPM слишком далеко — сузь разницу или поставь rates вручную.";
    return;
  }
  err.textContent = "";
  params.rateA = match.rateA;
  params.rateB = match.rateB;
  params.targetBPM = match.targetBPM;
  document.querySelector<HTMLInputElement>("#k-rateA")!.value = String(match.rateA);
  document.querySelector<HTMLInputElement>("#k-rateB")!.value = String(match.rateB);
  syncKnobOutputs();
  document.querySelector("#phase")!.textContent = `TEMPO LOCK ${Math.round(match.targetBPM)}`;
});

document.querySelector("#exportBtn")?.addEventListener("click", () => {
  syncKnobOutputs();
  const payload = {
    engine: "AutomixAI",
    ...params,
    bpmA: engine.getDeck("a").bpm,
    bpmB: engine.getDeck("b").bpm,
    trackA: engine.getDeck("a").name,
    trackB: engine.getDeck("b").name,
    profileA: profiles.a
      ? { bpm: profiles.a.bpm, mixIn: profiles.a.mixInSec, mixOut: profiles.a.mixOutSec }
      : null,
    profileB: profiles.b
      ? { bpm: profiles.b.bpm, mixIn: profiles.b.mixInSec, mixOut: profiles.b.mixOutSec }
      : null,
    exportedAt: new Date().toISOString(),
  };
  const box = document.querySelector<HTMLTextAreaElement>("#preset")!;
  box.value = JSON.stringify(payload, null, 2);
  void navigator.clipboard?.writeText(box.value);
});

document.querySelector("#importBtn")?.addEventListener("click", () => {
  const box = document.querySelector<HTMLTextAreaElement>("#preset")!;
  const err = document.querySelector("#error")!;
  try {
    const data = JSON.parse(box.value) as Partial<MashupParams> & {
      bpmA?: number;
      bpmB?: number;
      params?: MashupParams;
    };
    const src = data.params ?? data;
    Object.assign(params, defaultParams(), src);
    applyParamsToUI(params, data.bpmA, data.bpmB);
    err.textContent = "";
  } catch {
    err.textContent = "Невалидный JSON пресета";
  }
});

document.querySelector("#resetBtn")?.addEventListener("click", () => {
  const fresh = defaultParams();
  Object.assign(params, fresh);
  params.dsp = fresh.dsp;
  for (const k of knobs) {
    document.querySelector<HTMLInputElement>(`#k-${k.key}`)!.value = String(params[k.key]);
  }
  showProcessing([]);
  syncKnobOutputs();
});

engine.onUpdate((snap) => {
  const fill = document.querySelector<HTMLDivElement>("#fill")!;
  fill.style.width = `${(snap.progress * 100).toFixed(2)}%`;
  document.querySelector("#timeLeft")!.textContent = fmtTime(snap.displayElapsed);
  document.querySelector("#timeRight")!.textContent =
    "-" + fmtTime(Math.max(0, snap.displayDuration - snap.displayElapsed));
  document.querySelector("#phase")!.textContent = snap.phase;
  document.querySelector<HTMLElement>("#volA")!.style.width = `${snap.volA * 100}%`;
  document.querySelector<HTMLElement>("#volB")!.style.width = `${snap.volB * 100}%`;
  document.querySelector<HTMLElement>("#bassA")!.style.width = `${Math.max(0, 100 + snap.bassA * (100 / 15))}%`;
  document.querySelector<HTMLElement>("#bassB")!.style.width = `${Math.max(0, 100 + snap.bassB * (100 / 15))}%`;
  document.querySelector<HTMLElement>("#instrA")!.style.width = `${snap.instrA * 100}%`;
  document.querySelector<HTMLElement>("#instrB")!.style.width = `${snap.instrB * 100}%`;
  document.querySelector<HTMLElement>("#vocalB")!.style.width = `${snap.vocalB * 100}%`;
  document.querySelector<HTMLElement>("#hpfA")!.style.width = `${snap.hpfA * 100}%`;
  document.querySelector<HTMLElement>("#lpfB")!.style.width = `${snap.lpfB * 100}%`;
  document.querySelector<HTMLElement>("#echoA")!.style.width = `${snap.echoA * 100}%`;
  document.querySelector("#mixing")!.classList.toggle("on", snap.playing && snap.phase !== "READY");
  if (snap.processingNote && snap.playing) {
    // keep phase as DJ act; status already set during bake
  }
});

/** Offline Mid/Side stem preview (instrumentalize A / vocalize B). */
async function previewStem(id: "a" | "b", mode: "instrumental" | "vocal") {
  const deck = engine.getDeck(id);
  if (!deck.buffer) throw new Error(`Нет трека ${id.toUpperCase()}`);
  const ctx = await engine.ensureContext();
  const processed = processBufferStem(ctx, deck.buffer, mode, 1);
  // Swap buffer for preview, then restore after stop is user's job via reload —
  // keep original and play a one-shot source instead.
  const cue = id === "a" ? params.cueASec : params.cueBSec;
  engine.stop();
  const src = ctx.createBufferSource();
  src.buffer = processed;
  const g = ctx.createGain();
  g.gain.value = 0.95;
  src.connect(g);
  g.connect(ctx.destination);
  src.start(ctx.currentTime, Math.max(0, cue));
  src.stop(ctx.currentTime + Math.min(12, Math.max(4, deck.duration - cue)));
  document.querySelector("#phase")!.textContent =
    mode === "instrumental" ? `STEM A INSTRUMENTAL` : `STEM B VOCAL`;
  document.querySelector("#mixing")!.classList.remove("on");
}

document.querySelector("#previewInstrA")?.addEventListener("click", () => {
  void previewStem("a", "instrumental").catch((e) => {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
  });
});
document.querySelector("#previewVocalB")?.addEventListener("click", () => {
  void previewStem("b", "vocal").catch((e) => {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
  });
});

wireKnobs();
syncKnobOutputs();
