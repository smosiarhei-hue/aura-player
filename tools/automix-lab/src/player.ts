import "./player.css";
import { WaveRadio, type WaveRadioSnapshot } from "./audio/waveRadio";
import { PREMIUM_FEATURES } from "./audio/premiumAutomix";

const radio = new WaveRadio();
let pollTimer: number | null = null;
let openSheet: "lyrics" | "queue" | "more" | "auth" | null = null;

function icon(
  name: "play" | "pause" | "skip" | "prev" | "stop" | "lyrics" | "queue" | "more" | "link" | "x"
): string {
  const paths: Record<string, string> = {
    play: '<path d="M8 5.2v13.6l11.2-6.8L8 5.2z" fill="currentColor"/>',
    pause: '<path d="M6.5 5h3.2v14H6.5V5zm7.8 0H17.5v14h-3.2V5z" fill="currentColor"/>',
    skip: '<path d="M5 5.5l9.5 6.5L5 18.5V5.5zM16.2 5.5h2.3v13h-2.3v-13z" fill="currentColor"/>',
    prev: '<path d="M19 5.5l-9.5 6.5L19 18.5V5.5zM5.5 5.5h2.3v13H5.5v-13z" fill="currentColor"/>',
    stop: '<rect x="6.5" y="6.5" width="11" height="11" rx="2" fill="currentColor"/>',
    lyrics:
      '<path d="M5 7.5h14v1.6H5V7.5zm0 4h11v1.6H5V11.5zm0 4h8v1.6H5V15.5z" fill="currentColor"/>',
    queue:
      '<path d="M5 6.5h14v1.7H5V6.5zm0 5h14v1.7H5v-1.7zm0 5h9v1.7H5V16.5z" fill="currentColor"/>',
    more: '<circle cx="6.5" cy="12" r="1.4" fill="currentColor"/><circle cx="12" cy="12" r="1.4" fill="currentColor"/><circle cx="17.5" cy="12" r="1.4" fill="currentColor"/>',
    link: '<path d="M10.2 13.8a3.4 3.4 0 0 1 0-4.8l1.7-1.7a3.4 3.4 0 1 1 4.8 4.8l-.8.8-.1-1.5.5-.5a1.9 1.9 0 1 0-2.7-2.7l-1.7 1.7a1.9 1.9 0 0 0 0 2.7l.4.4-1.1 1.1-.5-.5zm3.6-3.6a3.4 3.4 0 0 1 0 4.8l-1.7 1.7a3.4 3.4 0 1 1-4.8-4.8l.8-.8.1 1.5-.5.5a1.9 1.9 0 1 0 2.7 2.7l1.7-1.7a1.9 1.9 0 0 0 0-2.7l-.4-.4 1.1-1.1.5.5z" fill="currentColor"/>',
    x: '<path d="M7.2 6.4 12 11.2l4.8-4.8 1.1 1.1L13.1 12l4.8 4.8-1.1 1.1L12 13.1l-4.8 4.8-1.1-1.1L10.9 12 6.1 7.5l1.1-1.1z" fill="currentColor"/>',
  };
  return `<svg viewBox="0 0 24 24" aria-hidden="true">${paths[name]}</svg>`;
}

function fmt(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) sec = 0;
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

const app = document.querySelector<HTMLDivElement>("#app")!;
app.innerHTML = `
  <div class="stage" id="stage">
    <div class="ambient" id="ambient" aria-hidden="true"></div>
    <div class="specular" aria-hidden="true"></div>

    <header class="chrome">
      <div class="brand-row">
        <div class="brand">Sonivo <em>Automix</em></div>
        <div class="pill glass-soft" id="queuePill"><span class="dot"></span><span id="queueLabel">Моя волна</span></div>
      </div>
      <div class="island" id="island" aria-live="polite">
        <span class="label" id="islandLabel">Ready</span>
        <span class="phase" id="islandPhase"></span>
      </div>
    </header>

    <main class="now">
      <div class="art-wrap" id="artWrap">
        <div class="art-orbit" aria-hidden="true"></div>
        <div class="mix-veil" id="mixVeil" aria-hidden="true"></div>
        <div class="art-card" id="artStage">
          <div class="art-fallback" id="artFallback">S</div>
          <img class="outgoing" id="coverA" alt="" hidden />
          <img class="incoming" id="coverB" alt="" hidden />
          <div class="mix-badge-float" id="mixFloat" hidden>MASHUP</div>
        </div>
      </div>

      <div class="meta" id="metaBlock">
        <div class="title-mask">
          <h1 id="title">Моя волна</h1>
        </div>
        <div class="artist-mask">
          <div class="artist" id="artist">Яндекс Музыка · live mashup</div>
        </div>
        <div class="next" id="nextLine">Подключи Яндекс — дальше играет плеер</div>
        <div class="mode-chip glass-soft" id="modeChip" hidden></div>
      </div>

      <div class="timeline">
        <div class="scrub" id="scrub" role="slider" aria-label="Перемотка до Automix" tabindex="0">
          <div class="scrub-track">
            <i class="scrub-fill" id="fill"></i>
            <b class="automix-mark" id="automixMark" hidden title="Automix"></b>
            <span class="scrub-thumb" id="scrubThumb"></span>
          </div>
        </div>
        <div class="times">
          <span id="tLeft">0:00</span>
          <span id="tRight">-0:00</span>
        </div>
        <div class="cue-line" id="cueLine">
          <span class="mixing-word" id="mixingWord" hidden>Mixing</span>
          <span class="cue-rest" id="cueRest"></span>
        </div>
      </div>

      <div class="transport">
        <div class="side-group">
          <button class="icon-btn" id="btnStop" type="button" aria-label="Stop">${icon("stop")}</button>
        </div>
        <button class="play" id="btnPlay" type="button" aria-label="Play">${icon("play")}</button>
        <div class="side-group">
          <button class="icon-btn" id="btnSkip" type="button" aria-label="Next">${icon("skip")}</button>
        </div>
      </div>

      <div class="action-row">
        <button class="action glass-soft" id="btnLyrics" type="button">${icon("lyrics")} Текст</button>
        <button class="action glass-soft" id="btnQueue" type="button">${icon("queue")} Очередь</button>
        <button class="action glass-soft" id="btnMore" type="button">${icon("more")} Ещё</button>
        <button class="action glass-soft" id="btnAuth" type="button">${icon("link")} Яндекс</button>
      </div>

      <div class="status-line" id="status">Premium AutoMix · LOCK → MASHUP → LAND</div>
      <div class="quality glass-soft" id="qualityBadge" hidden></div>
    </main>

    <div class="sheet-host" id="sheetHost" data-sheet="">
      <div class="sheet-backdrop" id="sheetBackdrop"></div>
      <section class="sheet glass" id="sheet" role="dialog" aria-modal="true" aria-labelledby="sheetTitle">
        <div class="sheet-handle" aria-hidden="true"></div>
        <div class="sheet-head">
          <h2 id="sheetTitle">Текст</h2>
          <button class="sheet-close" id="sheetClose" type="button" aria-label="Закрыть">${icon("x")}</button>
        </div>
        <div class="sheet-body" id="sheetBody"></div>
      </section>
    </div>
  </div>
`;

const sheetBodies = {
  lyrics: () => `
    <div class="transcript-status" id="transcriptStatus">LRC Яндекса или Whisper — строки с часами плеера</div>
    <div class="lyrics" id="lyricsSync"></div>
  `,
  queue: () => `
    <div class="queue-card glass-soft" id="nowCard">
      <div class="queue-ph" id="nowPh">S</div>
      <img id="nowCover" alt="" hidden />
      <div>
        <div class="t" id="nowTitle">—</div>
        <div class="a" id="nowArtist">Сейчас</div>
      </div>
    </div>
    <div class="queue-card glass-soft" id="nextCard">
      <div class="queue-ph" id="nextPh">N</div>
      <img id="nextCover" alt="" hidden />
      <div>
        <div class="t" id="upNextTitle">—</div>
        <div class="a" id="upNextArtist">Далее · после Automix</div>
      </div>
    </div>
    <div class="transition-panel">
      <div class="st-head">
        <span class="platters" aria-hidden="true"><i></i><i></i></span>
        <div>
          <strong>Song Transitions</strong>
          <p class="st-hint" id="stHint">AutoMix</p>
        </div>
      </div>
      <div class="transition-modes" id="transitionModes" role="radiogroup" aria-label="Song Transitions">
        <button type="button" class="tmode" role="radio" data-mode="automix" aria-checked="true" title="AutoMix — beatmatched blend">
          <span class="platters mini" aria-hidden="true"><i></i><i></i></span>
          <span>AutoMix</span>
        </button>
        <button type="button" class="tmode" role="radio" data-mode="duet" aria-checked="false" title="Adaptive Duet — listens to phrases, B-led dual (A ducked), early LAND B">
          <span class="platters mini" aria-hidden="true"><i></i><i></i></span>
          <span>Duet</span>
        </button>
        <button type="button" class="tmode" role="radio" data-mode="crossfade" aria-checked="false" title="Crossfade 1–12s">
          <span class="platters mini" aria-hidden="true"><i></i><i></i></span>
          <span>Crossfade</span>
        </button>
        <button type="button" class="tmode" role="radio" data-mode="off" aria-checked="false" title="Play to the end">
          <span class="platters mini off" aria-hidden="true"><i></i></span>
          <span>Off</span>
        </button>
      </div>
      <label class="xfade-row" id="xfadeRow">
        <span>Crossfade</span>
        <input id="xfadeSec" type="range" min="1" max="12" step="1" value="8" />
        <span id="xfadeVal">8s</span>
      </label>
    </div>
  `,
  more: () => `
    <div class="coach-block">
      <div class="sheet-head" style="padding:0"><strong>Transition Coach</strong></div>
      <div class="coach-score" id="coachScore">—</div>
      <div class="coach-story" id="coachStory">После mashup: лог → оценка → сдвиг offsets</div>
      <div class="coach-avg" id="coachAvg"></div>
    </div>
    <div class="premium-block">
      <div class="sheet-head" style="padding:0;margin-top:12px"><strong>Premium · всегда on</strong></div>
      <ul class="premium-list">
        ${PREMIUM_FEATURES.map(
          (f) => `<li><strong>${f.label}</strong><span>${f.detail}</span></li>`
        ).join("")}
      </ul>
    </div>
    <div class="foot-mini">
      <span>Streaming · Yandex API</span>
      <a href="/lab.html">DSP Lab</a>
    </div>
  `,
  auth: () => `
    <div class="auth-block" id="authBox">
      <h3>Sonivo · Яндекс Plus</h3>
      <p>Моя волна + Whisper/LRC brain: слушает фразу, планирует mashup 12–16 тактов, ровный LAND. FLAC при RU/BY IP, иначе nq/192.</p>
      <div class="auth-row">
        <button class="btn primary" id="ymConnect" type="button">Подключить</button>
        <button class="btn ghost" id="ymLogout" type="button">Выйти</button>
      </div>
      <div id="ymPending" hidden>
        <div class="code" id="ymCode">————</div>
        <a id="ymLink" href="#" target="_blank" rel="noopener">Открыть ya.ru/device</a>
        <p id="ymHint">Введи код — токен подхватится сам.</p>
      </div>
    </div>
  `,
};

function setSheet(kind: typeof openSheet) {
  openSheet = kind;
  const host = document.querySelector<HTMLElement>("#sheetHost")!;
  const title = document.querySelector("#sheetTitle")!;
  const body = document.querySelector("#sheetBody")!;
  const titles = {
    lyrics: "Текст",
    queue: "Очередь",
    more: "Ещё",
    auth: "Яндекс",
  } as const;

  document.querySelectorAll(".action").forEach((el) => el.classList.remove("on"));
  if (!kind) {
    host.classList.remove("open");
    host.dataset.sheet = "";
    return;
  }

  title.textContent = titles[kind];
  body.innerHTML = sheetBodies[kind]();
  host.dataset.sheet = kind;
  host.classList.add("open");
  const actionIds = {
    lyrics: "#btnLyrics",
    queue: "#btnQueue",
    more: "#btnMore",
    auth: "#btnAuth",
  } as const;
  document.querySelector(actionIds[kind])?.classList.add("on");

  if (kind === "auth") wireAuthButtons();
  if (kind === "queue") wireTransitionControls();
  render(radio.snapshot());
}

function wireTransitionControls() {
  const modes = document.querySelector<HTMLElement>("#transitionModes");
  if (!modes || modes.dataset.wired === "1") return;
  modes.dataset.wired = "1";
  modes.querySelectorAll<HTMLButtonElement>(".tmode").forEach((btn) => {
    btn.addEventListener("click", () => {
      const mode = btn.dataset.mode as "automix" | "duet" | "crossfade" | "off";
      if (mode) radio.setTransitionMode(mode);
    });
  });
  const slider = document.querySelector<HTMLInputElement>("#xfadeSec");
  slider?.addEventListener("input", () => {
    const v = Number(slider.value);
    radio.setCrossfadeSec(v);
    const lab = document.querySelector("#xfadeVal");
    if (lab) lab.textContent = `${v}s`;
  });
}

function wireAuthButtons() {
  document.querySelector("#ymConnect")?.addEventListener("click", () => {
    void connectYm({ autoPlay: false }).catch((e) => {
      document.querySelector("#status")!.textContent =
        e instanceof Error ? e.message : String(e);
    });
  });
  document.querySelector("#ymLogout")?.addEventListener("click", () => {
    stopPoll();
    playAfterAuth = false;
    radio.stop();
    void fetch("/api/ym/logout", { method: "POST" }).then(() => refreshAuthUi());
  });
}

function setCover(img: HTMLImageElement, url: string | null | undefined, fallback: HTMLElement) {
  if (!url) {
    img.hidden = true;
    img.removeAttribute("src");
    fallback.hidden = false;
    return;
  }
  img.onload = () => {
    img.hidden = false;
    fallback.hidden = true;
  };
  img.onerror = () => {
    img.hidden = true;
    fallback.hidden = false;
  };
  if (img.src !== url) img.src = url;
}

function sampleArtColor(url: string | null | undefined) {
  const ambient = document.querySelector<HTMLElement>("#ambient")!;
  if (!url) {
    ambient.style.removeProperty("--art-url");
    ambient.style.setProperty("--art-glow", "#3a2a40");
    return;
  }
  ambient.style.setProperty("--art-url", `url("${url}")`);
  const img = new Image();
  img.crossOrigin = "anonymous";
  img.onload = () => {
    try {
      const c = document.createElement("canvas");
      c.width = 16;
      c.height = 16;
      const ctx = c.getContext("2d");
      if (!ctx) return;
      ctx.drawImage(img, 0, 0, 16, 16);
      const data = ctx.getImageData(0, 0, 16, 16).data;
      let r = 0;
      let g = 0;
      let b = 0;
      let n = 0;
      for (let i = 0; i < data.length; i += 16) {
        r += data[i]!;
        g += data[i + 1]!;
        b += data[i + 2]!;
        n++;
      }
      r = (r / n) | 0;
      g = (g / n) | 0;
      b = (b / n) | 0;
      ambient.style.setProperty("--art-glow", `rgb(${r}, ${g}, ${b})`);
    } catch {
      /* CORS-tainted covers still drive blur via CSS url */
    }
  };
  img.src = url;
}

let lastTitleKey = "";
let metaSwapTimer: number | null = null;

function swapMetaText(titleEl: HTMLElement, artistEl: HTMLElement, title: string, artist: string) {
  const meta = document.querySelector<HTMLElement>("#metaBlock")!;
  const key = `${title}·${artist}`;
  if (key === lastTitleKey) {
    titleEl.textContent = title;
    artistEl.textContent = artist;
    return;
  }
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce || !lastTitleKey) {
    lastTitleKey = key;
    titleEl.textContent = title;
    artistEl.textContent = artist;
    return;
  }
  if (metaSwapTimer != null) window.clearTimeout(metaSwapTimer);
  meta.classList.remove("swap-in");
  meta.classList.add("swap-out");
  metaSwapTimer = window.setTimeout(() => {
    titleEl.textContent = title;
    artistEl.textContent = artist;
    lastTitleKey = key;
    meta.classList.remove("swap-out");
    meta.classList.add("swap-in");
    metaSwapTimer = window.setTimeout(() => meta.classList.remove("swap-in"), 450);
  }, 200);
}

function render(s: WaveRadioSnapshot) {
  const title = document.querySelector<HTMLElement>("#title")!;
  const artist = document.querySelector<HTMLElement>("#artist")!;
  const nextLine = document.querySelector("#nextLine")!;
  const status = document.querySelector("#status")!;
  const stage = document.querySelector<HTMLElement>("#stage")!;
  const island = document.querySelector<HTMLElement>("#island")!;
  const islandLabel = document.querySelector("#islandLabel")!;
  const islandPhase = document.querySelector("#islandPhase")!;
  const fill = document.querySelector<HTMLElement>("#fill")!;
  const thumb = document.querySelector<HTMLElement>("#scrubThumb")!;
  const tLeft = document.querySelector("#tLeft")!;
  const tRight = document.querySelector("#tRight")!;
  const art = document.querySelector("#artStage")!;
  const mixFloat = document.querySelector<HTMLElement>("#mixFloat")!;
  const modeChip = document.querySelector<HTMLElement>("#modeChip")!;
  const queuePill = document.querySelector<HTMLElement>("#queuePill")!;
  const queueLabel = document.querySelector("#queueLabel")!;
  const playBtn = document.querySelector("#btnPlay")!;
  const coverA = document.querySelector<HTMLImageElement>("#coverA")!;
  const coverB = document.querySelector<HTMLImageElement>("#coverB")!;
  const fallback = document.querySelector<HTMLElement>("#artFallback")!;

  status.textContent = s.status || "Premium AutoMix · LOCK → MASHUP → LAND";

  const live = s.state === "playing" || s.state === "mixing" || s.state === "loading";
  const isLand = s.mixing && (s.phase === "LAND" || s.progress >= 0.72);
  stage.classList.toggle("is-mixing", s.mixing);
  stage.classList.toggle("is-land", isLand);
  stage.style.setProperty("--mix-p", String(s.mixing ? Math.min(1, Math.max(0, s.progress)) : 0));

  queuePill.classList.toggle("live", s.state === "playing");
  queuePill.classList.toggle("mix", s.state === "mixing" && !isLand);
  queuePill.classList.toggle("land", isLand);
  queueLabel.textContent =
    s.state === "mixing"
      ? "Mixing"
      : s.state === "playing"
        ? "Моя волна · live"
        : "Моя волна";

  island.classList.toggle(
    "expanded",
    s.mixing || s.state === "loading" || Boolean(s.brainStatus)
  );
  island.classList.toggle("mixing", s.mixing);
  island.classList.toggle("land", isLand);
  if (s.mixing) {
    islandLabel.textContent = "Mixing";
    islandPhase.textContent = s.phase && s.phase !== "PLAY" ? s.phase : "";
  } else if (s.state === "loading") {
    islandLabel.textContent = s.brainStatus || "Loading";
    islandPhase.textContent = "";
  } else if (s.state === "playing") {
    islandLabel.textContent = s.brainStatus
      ? s.brainStatus.replace(/^Automix · /, "")
      : "Now Playing";
    islandPhase.textContent =
      s.transitionMode === "crossfade"
        ? `${s.crossfadeSec}s`
        : s.transitionMode === "off"
          ? "Off"
          : s.automixAtSec != null && !s.brainStatus?.includes("счита")
            ? `AM ${fmt(s.automixAtSec)}`
            : s.phase && s.phase !== "PLAY"
              ? s.phase
              : "";
  } else if (s.state === "needAuth") {
    islandLabel.textContent = "Connect Yandex";
    islandPhase.textContent = "";
  } else {
    islandLabel.textContent = "Ready";
    islandPhase.textContent = "";
  }

  mixFloat.hidden = !s.mixing;
  mixFloat.textContent = s.phase && s.phase !== "PLAY" ? s.phase : "Mixing";

  if (openSheet === "queue") {
    document.querySelectorAll<HTMLButtonElement>(".tmode").forEach((btn) => {
      const on = btn.dataset.mode === s.transitionMode;
      btn.classList.toggle("on", on);
      btn.setAttribute("aria-checked", on ? "true" : "false");
    });
    const hint = document.querySelector("#stHint");
    if (hint) {
      hint.textContent =
        s.transitionMode === "crossfade"
          ? `Equal-power · ${s.crossfadeSec}s`
          : s.transitionMode === "off"
            ? "Play to the end, then the next song"
            : s.transitionMode === "duet"
              ? "Duet · listens · stretch/key · B-led · stems/FX · LAND"
              : "Beatmatched blend · Crossfade if the plan is late";
    }
    const row = document.querySelector<HTMLElement>("#xfadeRow");
    if (row) row.hidden = s.transitionMode !== "crossfade";
    const slider = document.querySelector<HTMLInputElement>("#xfadeSec");
    const lab = document.querySelector("#xfadeVal");
    if (slider && Number(slider.value) !== s.crossfadeSec) {
      slider.value = String(s.crossfadeSec);
    }
    if (lab) lab.textContent = `${s.crossfadeSec}s`;
  }

  const q = document.querySelector<HTMLElement>("#qualityBadge")!;
  if (s.quality) {
    q.hidden = false;
    q.textContent = s.quality;
    q.dataset.q = s.quality.startsWith("FLAC")
      ? "lossless"
      : s.quality.startsWith("HQ")
        ? "hq"
        : "nq";
    q.title = s.qualityNote || s.quality;
  } else {
    q.hidden = true;
  }

  const cur = s.current;
  if (cur) {
    swapMetaText(title, artist, cur.title, cur.artists);
    setCover(coverA, cur.coverUrl, fallback);
    fallback.textContent = (cur.title[0] || "S").toUpperCase();
    sampleArtColor(cur.coverUrl);
  } else {
    swapMetaText(title, artist, "Моя волна", "Яндекс Музыка · live mashup");
    sampleArtColor(null);
  }

  if (s.next) {
    nextLine.innerHTML = `Далее · <strong>${s.next.artists} — ${s.next.title}</strong>`;
    setCover(coverB, s.next.coverUrl, fallback);
  } else {
    nextLine.textContent =
      s.state === "needAuth" ? "Сначала Яндекс" : "Ждём следующий из волны…";
  }

  if (s.planMode || s.planBlurb) {
    modeChip.hidden = false;
    modeChip.dataset.mode = s.planMode || "";
    modeChip.textContent = s.planBlurb || s.planMode || "";
  } else {
    modeChip.hidden = true;
  }

  const dur = s.duration || 1;
  const elapsed = s.elapsed || 0;
  const pct = s.mixing ? s.progress * 100 : Math.min(100, (elapsed / dur) * 100);
  fill.style.width = `${pct}%`;
  thumb.style.left = `${pct}%`;
  tLeft.textContent = fmt(elapsed);
  tRight.textContent = `-${fmt(Math.max(0, dur - elapsed))}`;

  const mark = document.querySelector<HTMLElement>("#automixMark")!;
  const cueLine = document.querySelector<HTMLElement>("#cueLine")!;
  const mixingWord = document.querySelector<HTMLElement>("#mixingWord")!;
  const cueRest = document.querySelector("#cueRest")!;
  const scrub = document.querySelector<HTMLElement>("#scrub")!;
  const showMark =
    (s.transitionMode === "automix" || s.transitionMode === "duet") &&
    s.automixAtSec != null &&
    dur > 0 &&
    !s.mixing;
  if (showMark && s.automixAtSec != null) {
    const markPct = Math.min(98, Math.max(2, (s.automixAtSec / dur) * 100));
    mark.hidden = false;
    mark.style.left = `${markPct}%`;
  } else {
    mark.hidden = true;
  }
  if (s.mixing) {
    mixingWord.hidden = false;
    cueLine.classList.add("is-mixing");
    cueRest.textContent = s.phase && s.phase !== "PLAY" ? s.phase : "";
  } else {
    mixingWord.hidden = true;
    cueLine.classList.remove("is-mixing");
    if (s.transitionMode === "duet" && s.automixAtSec != null && dur > 0) {
      const blend =
        s.blendSec != null && s.blendSec > 0 ? ` · ${Math.round(s.blendSec)}s` : "";
      cueRest.textContent = `Duet @ ${fmt(s.automixAtSec)}${blend}`;
    } else if (s.transitionMode === "automix" && s.automixAtSec != null && dur > 0) {
      cueRest.textContent = `Automix @ ${fmt(s.automixAtSec)}`;
    } else if (s.transitionMode === "crossfade" && dur > 0 && s.duration > 0) {
      cueRest.textContent = `Crossfade ${s.crossfadeSec}s`;
    } else if (s.transitionMode === "off" && s.state === "playing") {
      cueRest.textContent = "Off · до конца";
    } else {
      cueRest.textContent = "";
    }
  }
  scrub.classList.toggle("seekable", Boolean(s.canSeek));
  scrub.setAttribute("aria-valuemin", "0");
  scrub.setAttribute("aria-valuemax", String(s.scrubMaxSec ?? dur));
  scrub.setAttribute("aria-valuenow", String(elapsed));

  art.classList.toggle("mixing", s.mixing);
  art.classList.toggle("land", isLand);

  playBtn.innerHTML = live ? icon("pause") : icon("play");
  playBtn.setAttribute("aria-label", live ? "Pause" : "Play");

  if (openSheet === "lyrics") {
    const trStatus = document.querySelector("#transcriptStatus");
    const lyricsEl = document.querySelector<HTMLElement>("#lyricsSync");
    if (trStatus) {
      trStatus.textContent =
        s.transcriptStatus || "Текст появится после загрузки трека…";
    }
    if (lyricsEl) renderKaraoke(lyricsEl, s, elapsed);
  }

  if (openSheet === "queue") {
    const nowTitle = document.querySelector("#nowTitle");
    const nowArtist = document.querySelector("#nowArtist");
    const nowPh = document.querySelector<HTMLElement>("#nowPh");
    const nowCover = document.querySelector<HTMLImageElement>("#nowCover");
    const upTitle = document.querySelector("#upNextTitle");
    const upArtist = document.querySelector("#upNextArtist");
    const nextPh = document.querySelector<HTMLElement>("#nextPh");
    const nextCover = document.querySelector<HTMLImageElement>("#nextCover");
    if (nowTitle && nowArtist && nowPh && nowCover) {
      nowTitle.textContent = cur?.title || "—";
      nowArtist.textContent = cur?.artists || "Сейчас";
      nowPh.textContent = (cur?.title?.[0] || "S").toUpperCase();
      setCover(nowCover, cur?.coverUrl, nowPh);
    }
    if (upTitle && upArtist && nextPh && nextCover) {
      upTitle.textContent = s.next?.title || "—";
      const join =
        s.transitionMode === "crossfade"
          ? `Crossfade ${s.crossfadeSec}s`
          : s.transitionMode === "off"
            ? "после конца"
            : "после Automix";
      upArtist.textContent = s.next ? `${s.next.artists} · ${join}` : "Далее · ждём волну";
      nextPh.textContent = (s.next?.title?.[0] || "N").toUpperCase();
      setCover(nextCover, s.next?.coverUrl, nextPh);
    }
  }

  if (openSheet === "more") {
    const coachScore = document.querySelector("#coachScore");
    const coachStory = document.querySelector("#coachStory");
    const coachAvg = document.querySelector("#coachAvg");
    if (coachScore && s.coachScore != null) {
      coachScore.textContent = `${s.coachScore}/100`;
      coachScore.parentElement!.parentElement!.dataset.ok =
        s.coachScore >= 80 ? "1" : "0";
    }
    if (coachStory && s.coachStory) coachStory.textContent = s.coachStory;
    if (coachAvg && s.coachAvg != null) {
      coachAvg.textContent = `Среднее обучение · ${s.coachAvg}/100`;
    }
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

let lyricsKey = "";
let lastActiveLine = -1;
let lastScrollAt = 0;

function renderKaraoke(
  lyricsEl: HTMLElement,
  s: WaveRadioSnapshot,
  elapsed: number
) {
  const segs = s.transcript?.segments || [];
  const key = `${s.current?.id || ""}:${segs.length}:${s.transcript?.source || ""}`;
  if (!segs.length) {
    if (lyricsKey) {
      lyricsEl.innerHTML = "";
      lyricsKey = "";
      lastActiveLine = -1;
    }
    return;
  }

  if (lyricsKey !== key) {
    lyricsKey = key;
    lastActiveLine = -1;
    lyricsEl.innerHTML = segs
      .map((seg, i) => {
        const isCue =
          s.automixAtSec != null &&
          seg.end >= s.automixAtSec - 0.4 &&
          seg.start <= s.automixAtSec + 0.6;
        const words = seg.words?.length
          ? seg.words
              .map(
                (w, wi) =>
                  `<span class="lw" data-w="${wi}">${escapeHtml(w.text)}</span>`
              )
              .join(" ")
          : `<span class="lw" data-w="0">${escapeHtml(seg.text)}</span>`;
        return `<div class="line${isCue ? " cue" : ""}${i === 0 ? " active" : ""}" data-i="${i}">${words}</div>`;
      })
      .join("");
  }

  let activeIdx = -1;
  for (let i = 0; i < segs.length; i++) {
    const seg = segs[i]!;
    if (elapsed >= seg.start - 0.08 && elapsed < seg.end + 0.05) activeIdx = i;
  }
  if (activeIdx < 0) {
    for (let i = segs.length - 1; i >= 0; i--) {
      if (elapsed >= segs[i]!.start) {
        activeIdx = i;
        break;
      }
    }
  }

  const lines = lyricsEl.querySelectorAll<HTMLElement>(".line");
  lines.forEach((el, i) => {
    el.classList.toggle("active", i === activeIdx);
    const seg = segs[i];
    const wordEls = el.querySelectorAll<HTMLElement>(".lw");
    if (!seg?.words?.length) {
      wordEls.forEach((w) => w.classList.toggle("on", i === activeIdx));
      return;
    }
    wordEls.forEach((wEl, wi) => {
      const w = seg.words![wi];
      const on = Boolean(
        w && elapsed >= w.start - 0.04 && elapsed <= w.end + 0.12
      );
      wEl.classList.toggle("on", on);
    });
  });

  if (activeIdx >= 0 && activeIdx !== lastActiveLine) {
    lastActiveLine = activeIdx;
    const now = performance.now();
    if (now - lastScrollAt > 280) {
      lastScrollAt = now;
      const active = lines[activeIdx];
      if (active) active.scrollIntoView({ block: "center", behavior: "smooth" });
    }
  }
}

function seekFromClientX(clientX: number) {
  const scrub = document.querySelector<HTMLElement>("#scrub")!;
  const rect = scrub.getBoundingClientRect();
  const t = Math.min(1, Math.max(0, (clientX - rect.left) / Math.max(1, rect.width)));
  const snap = radio.snapshot();
  const dur = snap.duration || 1;
  const max = snap.scrubMaxSec ?? dur;
  radio.seekTo(t * dur > max ? max : t * dur);
}

/* ── Gaze / parallax on artwork ─────────────────────────────────── */

{
  const wrap = document.querySelector<HTMLElement>("#artWrap")!;
  const card = document.querySelector<HTMLElement>("#artStage")!;
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  let raf = 0;
  let targetX = 0;
  let targetY = 0;
  let curX = 0;
  let curY = 0;

  const tick = () => {
    curX += (targetX - curX) * 0.12;
    curY += (targetY - curY) * 0.12;
    card.style.transform = `rotateY(${curX}deg) rotateX(${curY}deg) translateZ(0)`;
    raf = requestAnimationFrame(tick);
  };

  if (!reduce) {
    raf = requestAnimationFrame(tick);
    wrap.addEventListener("pointermove", (e) => {
      const r = wrap.getBoundingClientRect();
      const nx = ((e.clientX - r.left) / r.width) * 2 - 1;
      const ny = ((e.clientY - r.top) / r.height) * 2 - 1;
      targetX = nx * 9;
      targetY = -ny * 7;
    });
    wrap.addEventListener("pointerleave", () => {
      targetX = 0;
      targetY = 0;
    });
  }

  window.addEventListener("beforeunload", () => cancelAnimationFrame(raf));
}

radio.onChange(render);

/* ── Sheets ─────────────────────────────────────────────────────── */

document.querySelector("#btnLyrics")?.addEventListener("click", () => {
  setSheet(openSheet === "lyrics" ? null : "lyrics");
});
document.querySelector("#btnQueue")?.addEventListener("click", () => {
  setSheet(openSheet === "queue" ? null : "queue");
});
document.querySelector("#btnMore")?.addEventListener("click", () => {
  setSheet(openSheet === "more" ? null : "more");
});
document.querySelector("#btnAuth")?.addEventListener("click", () => {
  setSheet(openSheet === "auth" ? null : "auth");
  if (openSheet === "auth") void refreshAuthUi();
});
document.querySelector("#sheetClose")?.addEventListener("click", () => setSheet(null));
document.querySelector("#sheetBackdrop")?.addEventListener("click", () => setSheet(null));
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") setSheet(null);
});

/* ─── Yandex auth ─────────────────────────────────────────────────── */

type YmStatus = {
  connected: boolean;
  login: string | null;
  pending: { userCode: string; verificationUrl: string; expiresAt: number } | null;
};

async function ymStatus(): Promise<YmStatus> {
  const r = await fetch("/api/ym/status");
  return (await r.json()) as YmStatus;
}

function stopPoll() {
  if (pollTimer != null) {
    window.clearInterval(pollTimer);
    pollTimer = null;
  }
}

function showPending(code: string, url: string) {
  if (openSheet !== "auth") setSheet("auth");
  const box = document.querySelector<HTMLElement>("#ymPending");
  if (!box) return;
  box.hidden = false;
  document.querySelector("#ymCode")!.textContent = code;
  const a = document.querySelector<HTMLAnchorElement>("#ymLink")!;
  a.href = url;
  a.textContent = url.replace(/^https?:\/\//, "");
}

let playAfterAuth = false;

async function refreshAuthUi() {
  const s = await ymStatus();
  if (openSheet !== "auth" && !s.pending) {
    /* keep primary view clean when already connected */
  } else if (openSheet !== "auth" && s.pending) {
    setSheet("auth");
  }
  const hint = document.querySelector("#ymHint");
  const pending = document.querySelector<HTMLElement>("#ymPending");
  if (!pending && openSheet === "auth") {
    // body just mounted
  }
  if (s.connected) {
    if (pending) pending.hidden = true;
    if (hint) hint.textContent = `Подключено · ${s.login || "yandex"}`;
    await radio.checkAuth();
    if (playAfterAuth) {
      playAfterAuth = false;
      setSheet(null);
      void radio.start().catch((e) => {
        document.querySelector("#status")!.textContent =
          e instanceof Error ? e.message : String(e);
      });
    }
  } else if (s.pending) {
    showPending(s.pending.userCode, s.pending.verificationUrl);
    if (hint) {
      hint.textContent = "Введи код на странице Яндекса — Play стартует сам";
    }
    await radio.checkAuth();
  } else {
    if (pending) pending.hidden = true;
    if (hint) hint.textContent = "Не подключено";
    await radio.checkAuth();
  }
}

async function connectYm(opts?: { autoPlay?: boolean }) {
  stopPoll();
  playAfterAuth = Boolean(opts?.autoPlay);
  const r = await fetch("/api/ym/auth/start", { method: "POST" });
  const body = (await r.json()) as {
    userCode?: string;
    verificationUrl?: string;
    intervalMs?: number;
    error?: string;
  };
  if (!r.ok || !body.userCode || !body.verificationUrl) {
    throw new Error(body.error || "auth start failed");
  }
  showPending(body.userCode, body.verificationUrl);
  document.querySelector("#status")!.textContent =
    `Код ${body.userCode} · подтверди на Яндексе`;
  window.open(body.verificationUrl, "_blank", "noopener");
  const interval = Math.max(3000, body.intervalMs || 5000);
  pollTimer = window.setInterval(() => {
    void (async () => {
      const pr = await fetch("/api/ym/auth/poll", { method: "POST" });
      if (pr.status === 202) return;
      if (pr.status === 410) {
        stopPoll();
        playAfterAuth = false;
        const hint = document.querySelector("#ymHint");
        if (hint) hint.textContent = "Код истёк — подключи снова";
        return;
      }
      if (pr.ok) {
        stopPoll();
        await refreshAuthUi();
      }
    })();
  }, interval);
}

document.querySelector("#btnPlay")?.addEventListener("click", () => {
  const s = radio.snapshot();
  if (s.state === "playing" || s.state === "mixing" || s.state === "loading") {
    radio.stop();
    return;
  }
  void (async () => {
    const st = await ymStatus();
    if (!st.connected) {
      await connectYm({ autoPlay: true });
      return;
    }
    await radio.start();
  })().catch((e) => {
    document.querySelector("#status")!.textContent =
      e instanceof Error ? e.message : String(e);
  });
});

document.querySelector("#btnStop")?.addEventListener("click", () => radio.stop());
document.querySelector("#btnSkip")?.addEventListener("click", () => {
  void radio.skip().catch((e) => {
    document.querySelector("#status")!.textContent =
      e instanceof Error ? e.message : String(e);
  });
});

{
  const scrub = document.querySelector<HTMLElement>("#scrub")!;
  let dragging = false;
  scrub.addEventListener("pointerdown", (e) => {
    if (!radio.snapshot().canSeek) return;
    dragging = true;
    scrub.setPointerCapture(e.pointerId);
    seekFromClientX(e.clientX);
  });
  scrub.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    seekFromClientX(e.clientX);
  });
  scrub.addEventListener("pointerup", () => {
    dragging = false;
  });
  scrub.addEventListener("pointercancel", () => {
    dragging = false;
  });
  scrub.addEventListener("keydown", (e) => {
    if (!radio.snapshot().canSeek) return;
    const cur = radio.snapshot().elapsed || 0;
    if (e.key === "ArrowRight") radio.seekTo(cur + 5);
    if (e.key === "ArrowLeft") radio.seekTo(cur - 5);
  });
}

void refreshAuthUi().catch(() => {
  document.querySelector("#status")!.textContent =
    "API Яндекса недоступен — перезапусти npm run dev";
});

// Keep Automix alive when the tab blurs / DevTools steals focus.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    void radio.resumeAudio();
  }
});

(window as unknown as { __sonivoPlayer: { radio: WaveRadio } }).__sonivoPlayer = {
  radio,
};
