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

/** Last Auto Mix plan + meter trail for Playwright / computerUse proofs. */
type MeterSample = {
  t: number;
  p: number;
  phase: string;
  instrA: number;
  instrB: number;
  volA: number;
  volB: number;
};
let lastPlan: ReturnType<typeof planAutomix> | null = null;
const meterTrail: MeterSample[] = [];
/** Keep full blend (~16s @ 60fps) so Vocal Relay proof sees early A-bed window. */
const MAX_TRAIL = 1200;

const app = document.querySelector<HTMLDivElement>("#app")!;
app.innerHTML = `
  <header class="hero">
    <h1>Automix <span>Lab</span></h1>
    <p>
      Консоль сведения Sonivo: BPM и Camelot → тип перехода → bake вокал/инструментал
      на окне A+B → LOCK → MASHUP → LAND. Один проход через Auto Mix.
      Dual mashup только если outro A уже инструментал — иначе Safe Exit.
    </p>
    <p class="hint">
      <a href="/">← Плеер Моя волна</a>
      · DSP-консоль ниже ·
      <a href="/iphone.html">макет iPhone</a>
    </p>
  </header>

  <div class="grid">
    <section class="panel">
      <h2>Деки</h2>
      <div class="decks">
        <div class="deck a">
          <div class="label">Deck A · outgoing</div>
          <label class="file-btn">Трек A
            <input id="fileA" type="file" accept="audio/*,.mp3,.wav,.m4a,.flac,.ogg" />
          </label>
          <div class="meta" id="metaA">файл не выбран</div>
          <div class="controls deck-controls">
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
          <div class="actions tight">
            <button class="ghost" id="soloA" type="button">Solo A от cue</button>
            <button class="ghost" id="analyzeA" type="button">Анализ A</button>
          </div>
        </div>
        <div class="deck b">
          <div class="label">Deck B · incoming</div>
          <label class="file-btn">Трек B
            <input id="fileB" type="file" accept="audio/*,.mp3,.wav,.m4a,.flac,.ogg" />
          </label>
          <div class="meta" id="metaB">файл не выбран</div>
          <div class="controls deck-controls">
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
          <div class="actions tight">
            <button class="ghost" id="soloB" type="button">Solo B от cue</button>
            <button class="ghost" id="analyzeB" type="button">Анализ B</button>
          </div>
        </div>
      </div>

      <div class="actions tight">
        <button class="ghost" id="loadSamples" type="button">Demo Midnight → Neon</button>
      </div>

      <div class="ym-panel" id="ymPanel">
        <div class="ym-head">
          <strong>Яндекс Музыка · Моя волна</strong>
          <span class="ym-login" id="ymLogin">не подключено</span>
        </div>
        <p class="hint ym-hint">
          Device Flow → браузер → два трека из «Моей волны» на деки → Auto Mix.
          Тест на реальных треках, не на промптах.
        </p>
        <div class="actions tight">
          <button class="primary" id="ymConnect" type="button">Подключить Яндекс</button>
          <button class="primary ai" id="ymWave" type="button" disabled>Моя волна → A/B</button>
          <button class="ghost" id="ymLogout" type="button" disabled>Выйти</button>
        </div>
        <div class="ym-auth" id="ymAuth" hidden>
          <div class="ym-code" id="ymCode">————</div>
          <a class="ym-link" id="ymLink" href="#" target="_blank" rel="noopener">Открыть авторизацию</a>
          <p class="hint" id="ymAuthHint">Введи код на странице Яндекса — Lab сам подхватит токен.</p>
        </div>
        <div class="ym-status" id="ymStatus">Ждём подключения…</div>
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
        <div class="critic" id="criticBadge" data-ok="idle">Mix Critic · —</div>
        <div class="ai-status" id="aiStatus">Загрузи A и B → Auto Mix</div>
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
          <button class="primary ai" id="aiAuto" type="button">Auto Mix</button>
          <button class="primary" id="play" type="button">Play mashup</button>
          <button class="warn" id="stop" type="button">Stop</button>
          <button class="ghost" id="matchTempo" type="button">Match BPM</button>
        </div>
        <div class="error" id="error"></div>
        <p class="hint">
          Auto Mix читает key и BPM, выбирает тип по §2.4, затем bake стемов и FX.
          Ручки справа — только override.
        </p>
        <ul class="dsp-list" id="processingList"></ul>
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
      <textarea class="preset-box" id="preset" spellcheck="false" placeholder="Пресет / AI plan…"></textarea>
      <p class="hint">
        Зеркало iOS <code>TrackAnalyzer</code> + <code>MashupLiveStyle.resolve</code>.
        DSP: <code>src/dsp/</code> — MidSideStem, BassEq, FilterSweep, EchoOut.
      </p>

      <h2 class="spaced">DSP</h2>
      <ul class="dsp-list">
        <li><strong>Mid/Side stem</strong> — A instrumentalize, B vocalize</li>
        <li><strong>Bass EQ</strong> — ONE BASS: kill A lows, restore B</li>
        <li><strong>HPF / LPF</strong> — HPF riser на A, LPF reveal на B</li>
        <li><strong>Echo-out</strong> — tempo-sync delay хвоста A поверх B</li>
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

function setCriticBadge(plan: { critic?: import("./audio/mixCritic").MixCriticReport } | null) {
  const el = document.querySelector<HTMLElement>("#criticBadge");
  if (!el) return;
  if (!plan?.critic) {
    el.dataset.ok = "idle";
    el.textContent = "Mix Critic · —";
    return;
  }
  const c = plan.critic;
  el.dataset.ok = c.ok ? "pass" : "fix";
  const fixes = c.fixes.length ? ` · ${c.fixes.join(" + ")}` : "";
  el.textContent = c.ok
    ? `Mix Critic ${c.score}/100 · pass`
    : `Mix Critic ${c.score}/100 · ${c.mode}${fixes}`;
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
  lastPlan = plan;
  meterTrail.length = 0;
  // Keep AI dsp recipe intact while syncing numeric knobs.
  const dsp = plan.params.dsp;
  applyParamsToUI(plan.params, plan.profileA.bpm, plan.profileB.bpm);
  params.dsp = dsp;
  engine.setParams(params);
  showProcessing(plan.processing);
  setCriticBadge(plan);
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
      critic: plan.critic,
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

async function loadUrlPair(
  urlA: string,
  urlB: string,
  nameA: string,
  nameB: string,
  opts?: { mime?: string; ext?: string }
) {
  const err = document.querySelector("#error")!;
  err.textContent = "";
  setAiStatus(`Загрузка ${nameA} / ${nameB}…`);
  const [ra, rb] = await Promise.all([fetch(urlA), fetch(urlB)]);
  if (!ra.ok || !rb.ok) throw new Error("Не удалось скачать samples");
  const [ba, bb] = await Promise.all([ra.arrayBuffer(), rb.arrayBuffer()]);
  const mime = opts?.mime ?? "audio/wav";
  const ext = opts?.ext ?? "wav";
  const fa = new File([ba], `${nameA}.${ext}`, { type: mime });
  const fb = new File([bb], `${nameB}.${ext}`, { type: mime });
  await onFile("a", fa);
  await onFile("b", fb);
}

/* ─── Yandex Music · Моя волна ─────────────────────────────────────── */

type YmStatus = {
  connected: boolean;
  login: string | null;
  pending: {
    userCode: string;
    verificationUrl: string;
    expiresAt: number;
  } | null;
};

type YmWavePair = {
  a: { id: string; title: string; artists: string; url: string; fileName: string };
  b: { id: string; title: string; artists: string; url: string; fileName: string };
};

let ymPollTimer: number | null = null;

function setYmStatus(msg: string) {
  const el = document.querySelector("#ymStatus");
  if (el) el.textContent = msg;
}

function setYmConnected(login: string | null) {
  const loginEl = document.querySelector<HTMLElement>("#ymLogin")!;
  const waveBtn = document.querySelector<HTMLButtonElement>("#ymWave")!;
  const logoutBtn = document.querySelector<HTMLButtonElement>("#ymLogout")!;
  const authEl = document.querySelector<HTMLElement>("#ymAuth")!;
  if (login) {
    loginEl.textContent = login;
    loginEl.dataset.on = "1";
    waveBtn.disabled = false;
    logoutBtn.disabled = false;
    authEl.hidden = true;
    setYmStatus(`Подключено как ${login}. Жми «Моя волна → A/B».`);
  } else {
    loginEl.textContent = "не подключено";
    delete loginEl.dataset.on;
    waveBtn.disabled = true;
    logoutBtn.disabled = true;
  }
}

async function ymFetchStatus(): Promise<YmStatus> {
  const r = await fetch("/api/ym/status");
  if (!r.ok) throw new Error(`ym status ${r.status}`);
  return (await r.json()) as YmStatus;
}

function stopYmPoll() {
  if (ymPollTimer != null) {
    window.clearInterval(ymPollTimer);
    ymPollTimer = null;
  }
}

async function ymPollOnce(): Promise<"ok" | "pending" | "expired"> {
  const r = await fetch("/api/ym/auth/poll", { method: "POST" });
  if (r.status === 202) return "pending";
  if (r.status === 410) return "expired";
  if (!r.ok) {
    const body = (await r.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error || `poll ${r.status}`);
  }
  const body = (await r.json()) as { status: string; login?: string };
  if (body.status === "ok") {
    setYmConnected(body.login || "yandex");
    stopYmPoll();
    return "ok";
  }
  return "pending";
}

function startYmPoll(intervalMs: number) {
  stopYmPoll();
  const tick = async () => {
    try {
      const st = await ymPollOnce();
      if (st === "pending") setYmStatus("Ждём подтверждения в браузере Яндекса…");
      if (st === "expired") {
        stopYmPoll();
        setYmStatus("Код истёк — нажми «Подключить Яндекс» снова.");
      }
    } catch (e) {
      stopYmPoll();
      setYmStatus(e instanceof Error ? e.message : String(e));
    }
  };
  void tick();
  ymPollTimer = window.setInterval(() => void tick(), Math.max(3000, intervalMs));
}

async function ymConnect() {
  const err = document.querySelector("#error")!;
  err.textContent = "";
  stopYmPoll();
  setYmStatus("Запрашиваю код устройства…");
  const r = await fetch("/api/ym/auth/start", { method: "POST" });
  const body = (await r.json()) as {
    userCode?: string;
    verificationUrl?: string;
    intervalMs?: number;
    error?: string;
  };
  if (!r.ok || !body.userCode || !body.verificationUrl) {
    throw new Error(body.error || "не удалось начать авторизацию");
  }
  const authEl = document.querySelector<HTMLElement>("#ymAuth")!;
  const codeEl = document.querySelector("#ymCode")!;
  const linkEl = document.querySelector<HTMLAnchorElement>("#ymLink")!;
  authEl.hidden = false;
  codeEl.textContent = body.userCode;
  linkEl.href = body.verificationUrl;
  linkEl.textContent = body.verificationUrl.replace(/^https?:\/\//, "");
  setYmStatus(`Открой ссылку и введи код ${body.userCode}`);
  // Open auth page for the user (same machine / forwarded browser).
  window.open(body.verificationUrl, "_blank", "noopener");
  startYmPoll(body.intervalMs || 5000);
}

async function ymLoadWavePair() {
  const err = document.querySelector("#error")!;
  err.textContent = "";
  setYmStatus("Тяну пару из «Моей волны»…");
  setAiStatus("Яндекс · Моя волна → скачиваю A/B…");
  const r = await fetch("/api/ym/wave/pair", { method: "POST" });
  const body = (await r.json()) as YmWavePair & { error?: string };
  if (!r.ok) throw new Error(body.error || `wave ${r.status}`);
  const labelA = `${body.a.artists} — ${body.a.title}`;
  const labelB = `${body.b.artists} — ${body.b.title}`;
  setYmStatus(`A: ${labelA}\nB: ${labelB}`);
  await loadUrlPair(body.a.url, body.b.url, labelA, labelB, {
    mime: "audio/mpeg",
    ext: "mp3",
  });
  setYmStatus(`На деках: ${labelA} → ${labelB}. Жми Auto Mix.`);
  setAiStatus(`Яндекс · готово · ${labelA} → ${labelB}`);
}

async function ymLogout() {
  stopYmPoll();
  await fetch("/api/ym/logout", { method: "POST" });
  setYmConnected(null);
  document.querySelector<HTMLElement>("#ymAuth")!.hidden = true;
  setYmStatus("Вышел. Можно подключить снова.");
}

document.querySelector("#ymConnect")?.addEventListener("click", () => {
  void ymConnect().catch((e) => {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
    setYmStatus("Ошибка авторизации");
  });
});
document.querySelector("#ymWave")?.addEventListener("click", () => {
  void ymLoadWavePair().catch((e) => {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
    setYmStatus(e instanceof Error ? e.message : String(e));
  });
});
document.querySelector("#ymLogout")?.addEventListener("click", () => {
  void ymLogout().catch((e) => {
    document.querySelector("#error")!.textContent = e instanceof Error ? e.message : String(e);
  });
});

void ymFetchStatus()
  .then((s) => {
    if (s.connected) setYmConnected(s.login);
    else if (s.pending) {
      const authEl = document.querySelector<HTMLElement>("#ymAuth")!;
      const codeEl = document.querySelector("#ymCode")!;
      const linkEl = document.querySelector<HTMLAnchorElement>("#ymLink")!;
      authEl.hidden = false;
      codeEl.textContent = s.pending.userCode;
      linkEl.href = s.pending.verificationUrl;
      linkEl.textContent = s.pending.verificationUrl.replace(/^https?:\/\//, "");
      setYmStatus(`Ждём код ${s.pending.userCode}…`);
      startYmPoll(5000);
    } else {
      setYmConnected(null);
      setYmStatus("Подключи Яндекс, чтобы слушать «Мою волну» в Lab.");
    }
  })
  .catch(() => {
    setYmStatus("API Яндекса недоступен — перезапусти npm run dev.");
  });

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
  if (snap.playing) {
    meterTrail.push({
      t: performance.now(),
      p: snap.progress,
      phase: snap.phase,
      instrA: snap.instrA,
      instrB: snap.instrB,
      volA: snap.volA,
      volB: snap.volB,
    });
    if (meterTrail.length > MAX_TRAIL) meterTrail.shift();
  }
});

/** Playwright / computerUse: drive Lab without clicking. */
type AutomixLabDebug = {
  loadDemo: () => Promise<void>;
  loadWave: () => Promise<void>;
  ymStatus: () => Promise<YmStatus>;
  autoMix: () => Promise<void>;
  stop: () => void;
  getTrail: () => MeterSample[];
  getPlan: () => {
    mode: string | null;
    vocalBAt: number;
    instrAAt: number;
    instrBUntil: number;
    story: string | null;
    criticOk: boolean | null;
  };
  relayProof: () => {
    ok: boolean;
    detail: string;
    aBedBeforeB: boolean;
    bOpenLate: boolean;
    noDualLead: boolean;
    samples: number;
  };
};
(window as unknown as { __automixLab: AutomixLabDebug }).__automixLab = {
  async loadDemo() {
    await loadUrlPair(
      "/samples/track-a-midnight.wav",
      "/samples/track-b-neon.wav",
      "midnight",
      "neon"
    );
  },
  async loadWave() {
    await ymLoadWavePair();
  },
  async ymStatus() {
    return ymFetchStatus();
  },
  async autoMix() {
    meterTrail.length = 0;
    if (!engine.getDeck("a").buffer || !engine.getDeck("b").buffer) {
      await this.loadDemo();
    }
    if (!profiles.a) await analyzeDeck("a");
    if (!profiles.b) await analyzeDeck("b");
    const plan = runPlanFromProfiles();
    setAiStatus(`4/4 · ${plan.story}`);
    await engine.playAutoMashup((msg) => setAiStatus(msg));
  },
  stop() {
    engine.stop();
  },
  getTrail() {
    return meterTrail.slice();
  },
  getPlan() {
    const dsp = lastPlan?.params.dsp;
    return {
      mode: dsp?.mashupMode ?? null,
      vocalBAt: dsp?.vocalBAt ?? 0,
      instrAAt: dsp?.instrAAt ?? 0,
      instrBUntil: dsp?.instrBUntil ?? 0,
      story: lastPlan?.story ?? null,
      criticOk: lastPlan?.critic?.ok ?? null,
    };
  },
  relayProof() {
    const plan = this.getPlan();
    const trail = meterTrail;
    if (!trail.length) {
      return {
        ok: false,
        detail: "no meter samples",
        aBedBeforeB: false,
        bOpenLate: false,
        noDualLead: false,
        samples: 0,
      };
    }
    const open = plan.vocalBAt || 0.4;
    const aReady = Math.max(0.08, plan.instrAAt || 0.1);
    // Early window AFTER A carve completes: A bed + B still gated until open.
    const early = trail.filter((s) => s.p >= aReady + 0.02 && s.p < open - 0.02);
    // After instrB bloom (~0.18) settles — B dry lead, A still carved + quiet.
    const settled = Math.min(0.88, open + 0.2);
    const late = trail.filter((s) => s.p >= settled && s.p <= Math.min(0.92, settled + 0.2));
    const aBedBeforeB =
      early.length >= 8 &&
      early.every((s) => s.instrA >= 0.85) &&
      early.every((s) => s.instrB >= 0.7);
    const bOpenLate =
      late.length >= 8 &&
      late.every((s) => s.instrA >= 0.85) &&
      late.every((s) => s.instrB <= 0.2) &&
      late.every((s) => s.volA <= s.volB * 0.45 + 0.06);
    // Dual lead = A not carved while B already dry.
    const clash = trail.filter(
      (s) =>
        s.p > 0.1 &&
        s.p < 0.9 &&
        s.instrA < 0.75 &&
        s.instrB < 0.35 &&
        s.volA > 0.35 &&
        s.volB > 0.55
    );
    const noDualLead = clash.length === 0;
    // ONE VOCAL:
    //   acapellaDrop — A bed × B vocal with early gate + late dry B
    //   safeExit     — A still sings → no dual mashup; noDualLead is enough
    const relay =
      plan.mode === "acapellaDrop" && aBedBeforeB && bOpenLate && noDualLead;
    const safe = plan.mode === "safeExit" && noDualLead;
    const ok = relay || safe;
    return {
      ok,
      detail: ok
        ? plan.mode === "safeExit"
          ? `Safe Exit ok · ONE VOCAL · dual=${clash.length}`
          : `Vocal Relay ok · open@${((open * 100) | 0)}% · early=${early.length} late=${late.length}`
        : `fail mode=${plan.mode} aBed=${aBedBeforeB} bOpen=${bOpenLate} dual=${!noDualLead} early=${early.length} late=${late.length}`,
      aBedBeforeB,
      bOpenLate,
      noDualLead,
      samples: trail.length,
    };
  },
};

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
