import "./style.css";
import { AutomixEngine } from "./audio/engine";
import { defaultParams, tempoMatch } from "./audio/envelopes";
import type { MashupParams } from "./audio/envelopes";

const params = defaultParams();
const engine = new AutomixEngine(params);

const app = document.querySelector<HTMLDivElement>("#app")!;
app.innerHTML = `
  <header class="hero">
    <h1>Automix <span>Lab</span></h1>
    <p>
      Локальный стенд для сведения двух треков как в Sonivo AutoMix Mashup:
      BPM в такт, бас от следующего, мэшап-слой A+B. Крути ручки на слух,
      экспортируй пресет в JSON.
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
          </div>
        </div>
      </div>

      <div class="transport">
        <div class="timeline"><div class="fill" id="fill"></div></div>
        <div class="times">
          <span id="timeLeft">0:00</span>
          <span class="mixing" id="mixing">Автомикс</span>
          <span id="timeRight">-0:00</span>
        </div>
        <div class="phase" id="phase">READY</div>
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
        <div class="actions">
          <button class="primary" id="play" type="button">▶ Play mashup</button>
          <button class="warn" id="stop" type="button">Stop</button>
          <button class="ghost" id="matchTempo" type="button">Match BPM → rates</button>
        </div>
        <div class="error" id="error"></div>
        <p class="hint">
          Подсказка: поставь Cue A в outro (инструментал), Cue B туда, где уже есть
          вокал/бит следующего трека. Play — оба слоя на общей сетке, на handoff
          шкала снэпается на B.
        </p>
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
      <textarea class="preset-box" id="preset" spellcheck="false" placeholder="Пресет появится здесь…"></textarea>
      <p class="hint">
        Поля совпадают с live <code>MashupLiveStyle</code> в aura-player.
        Rate меняет темп «винилово» (с питчем) — как у DJ beatmatch.
      </p>
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

function setParamNumber(key: keyof MashupParams, value: number) {
  switch (key) {
    case "archetype":
      return;
    default:
      params[key] = value;
  }
}

function syncKnobOutputs() {
  for (const k of knobs) {
    const input = document.querySelector<HTMLInputElement>(`#k-${k.key}`)!;
    const out = document.querySelector<HTMLOutputElement>(`#o-${k.key}`)!;
    const v = Number(input.value);
    setParamNumber(k.key, v);
    out.textContent = k.format ? k.format(v) : String(v);
  }
  params.cueASec = Number(document.querySelector<HTMLInputElement>("#cueA")!.value);
  params.cueBSec = Number(document.querySelector<HTMLInputElement>("#cueB")!.value);
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
  // Sensible defaults: A near outro, B past short intro
  if (id === "a" && Number(el.value) === 0 && duration > 40) {
    el.value = String(Math.max(0, duration - 24));
  }
  if (id === "b" && Number(el.value) === 0 && duration > 60) {
    el.value = String(Math.min(32, duration * 0.12));
  }
}

async function onFile(id: "a" | "b", file: File | undefined) {
  const err = document.querySelector("#error")!;
  err.textContent = "";
  if (!file) return;
  try {
    const deck = await engine.loadFile(id, file);
    const meta = document.querySelector(id === "a" ? "#metaA" : "#metaB")!;
    meta.innerHTML = `<strong>${deck.name}</strong><br>${deck.duration.toFixed(1)}s · ${deck.buffer?.numberOfChannels ?? 0}ch · ${deck.buffer?.sampleRate ?? 0} Hz`;
    setCueMax(id, deck.duration);
    syncKnobOutputs();
  } catch (e) {
    err.textContent = e instanceof Error ? e.message : String(e);
  }
}

document.querySelector("#fileA")?.addEventListener("change", (e) => {
  const f = (e.target as HTMLInputElement).files?.[0];
  void onFile("a", f);
});
document.querySelector("#fileB")?.addEventListener("change", (e) => {
  const f = (e.target as HTMLInputElement).files?.[0];
  void onFile("b", f);
});

document.querySelector("#play")?.addEventListener("click", async () => {
  const err = document.querySelector("#error")!;
  err.textContent = "";
  syncKnobOutputs();
  try {
    await engine.playMashup();
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
    ...params,
    bpmA: engine.getDeck("a").bpm,
    bpmB: engine.getDeck("b").bpm,
    trackA: engine.getDeck("a").name,
    trackB: engine.getDeck("b").name,
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
    const data = JSON.parse(box.value) as Partial<MashupParams> & { bpmA?: number; bpmB?: number };
    Object.assign(params, defaultParams(), data);
    for (const k of knobs) {
      const el = document.querySelector<HTMLInputElement>(`#k-${k.key}`);
      if (el && data[k.key] != null) el.value = String(data[k.key]);
    }
    if (data.cueASec != null) document.querySelector<HTMLInputElement>("#cueA")!.value = String(data.cueASec);
    if (data.cueBSec != null) document.querySelector<HTMLInputElement>("#cueB")!.value = String(data.cueBSec);
    if (data.bpmA != null) document.querySelector<HTMLInputElement>("#bpmA")!.value = String(data.bpmA);
    if (data.bpmB != null) document.querySelector<HTMLInputElement>("#bpmB")!.value = String(data.bpmB);
    syncKnobOutputs();
    err.textContent = "";
  } catch {
    err.textContent = "Невалидный JSON пресета";
  }
});

document.querySelector("#resetBtn")?.addEventListener("click", () => {
  Object.assign(params, defaultParams());
  for (const k of knobs) {
    document.querySelector<HTMLInputElement>(`#k-${k.key}`)!.value = String(params[k.key]);
  }
  syncKnobOutputs();
});

engine.onUpdate((snap) => {
  const fill = document.querySelector<HTMLDivElement>("#fill")!;
  fill.style.width = `${(snap.progress * 100).toFixed(2)}%`;
  // Apple-style hard snap of timeline numbers to display deck
  document.querySelector("#timeLeft")!.textContent = fmtTime(snap.displayElapsed);
  document.querySelector("#timeRight")!.textContent =
    "-" + fmtTime(Math.max(0, snap.displayDuration - snap.displayElapsed));
  document.querySelector("#phase")!.textContent = snap.phase;
  document.querySelector<HTMLElement>("#volA")!.style.width = `${snap.volA * 100}%`;
  document.querySelector<HTMLElement>("#volB")!.style.width = `${snap.volB * 100}%`;
  // Map bass dB (-15…0) to 0…100 bar
  document.querySelector<HTMLElement>("#bassA")!.style.width = `${Math.max(0, 100 + snap.bassA * (100 / 15))}%`;
  document.querySelector<HTMLElement>("#bassB")!.style.width = `${Math.max(0, 100 + snap.bassB * (100 / 15))}%`;
  document.querySelector("#mixing")!.classList.toggle("on", snap.playing && snap.phase !== "READY");
});

wireKnobs();
syncKnobOutputs();
