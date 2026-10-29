import "./iphone-mock.css";

type Screen = "player" | "tools" | "settings";
type Phase = "LOCK" | "INVITE B" | "ONE BASS" | "MASHUP" | "LAND" | "";

const PHASES: Phase[] = ["LOCK", "INVITE B", "ONE BASS", "MASHUP", "LAND"];

const state = {
  screen: "player" as Screen,
  mixing: true,
  phaseIdx: 2,
  playing: true,
  progress: 0.42,
  automixOn: true,
  stems: {
    instrA: true,
    vocalB: true,
    hpf: true,
    echo: true,
  },
  knobs: {
    blend: 16,
    bassSwap: 0.22,
    handoff: 0.52,
    bassDepth: 1.35,
    rateB: 1.032,
  },
  transition: "automix" as "gapless" | "crossfade" | "automix" | "off",
};

const stage = document.querySelector<HTMLDivElement>("#stage")!;

function icon(name: string): string {
  const paths: Record<string, string> = {
    chevron:
      '<path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>',
    more: '<circle cx="5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/>',
    shuffle:
      '<path d="M16 3h5v5M4 20l7-7M21 3l-7 7M21 16v5h-5M15 15l6 6M4 4l5 5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
    back: '<path d="M19 12H5M12 19l-7-7 7-7" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>',
    skipBack:
      '<path d="M19 20L9 12l10-8v16zM5 19V5" fill="currentColor"/>',
    skipFwd:
      '<path d="M5 4l10 8-10 8V4zM19 5v14" fill="currentColor"/>',
    play: '<path d="M8 5v14l11-7L8 5z" fill="currentColor"/>',
    pause: '<path d="M6 4h4v16H6V4zm8 0h4v16h-4V4z" fill="currentColor"/>',
    repeat:
      '<path d="M17 1l4 4-4 4M3 11V9a4 4 0 014-4h14M7 23l-4-4 4-4M21 13v2a4 4 0 01-4 4H3" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
    star: '<path d="M12 2l2.9 6.3L22 9.3l-5 4.9 1.2 7-6.2-3.3L5.8 21l1.2-7-5-4.9 7.1-1L12 2z" fill="currentColor"/>',
    quote:
      '<path d="M7 8h4v5H8c0 2 1 3 3 3v2c-3 0-5-2-5-5V8zm8 0h4v5h-3c0 2 1 3 3 3v2c-3 0-5-2-5-5V8z" fill="currentColor"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
    airplay:
      '<path d="M5 17H3a2 2 0 01-2-2V5a2 2 0 012-2h18a2 2 0 012 2v10a2 2 0 01-2 2h-2M12 15l5 6H7l5-6z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
    gear: '<path d="M12 15a3 3 0 100-6 3 3 0 000 6z"/><path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9c.3.6.9 1 1.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
  };
  return `<svg viewBox="0 0 24 24" aria-hidden="true">${paths[name] ?? ""}</svg>`;
}

function phaseLabel(): Phase {
  if (!state.mixing) return "";
  return PHASES[state.phaseIdx] ?? "MASHUP";
}

function artworkClass(): string {
  const p = phaseLabel();
  if (p === "MASHUP" || p === "ONE BASS") return "mashup";
  if (p === "LAND") return "land";
  return "";
}

function trackTitle(): string {
  const p = phaseLabel();
  if (p === "LAND" || (state.progress > 0.7 && state.mixing)) return "Neon Afterglow";
  return "Midnight Grid";
}

function trackArtist(): string {
  const p = phaseLabel();
  if (p === "LAND" || (state.progress > 0.7 && state.mixing)) return "Lumen Parade";
  return "Atlas Row";
}

function fmt(sec: number): string {
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function render() {
  const phase = phaseLabel();
  const elapsed = 148 + state.progress * 16;
  const remaining = 210 - elapsed;
  const artClass = artworkClass();
  const bgTint = artClass === "land" || phase === "LAND" ? "b-tint" : "";

  stage.innerHTML = `
    <aside class="side-copy">
      <h1 class="brand-mark">Sonivo<br/><span>Automix</span></h1>
      <p>
        Макет iPhone&nbsp;17&nbsp;Pro (402×874). Как выглядит приложение:
        плеер с Mixing, инструменты вокал/инструментал и ручная настройка сведения.
      </p>
      <div class="chips">
        <button class="chip ${state.screen === "player" ? "active" : ""}" data-nav="player">Плеер</button>
        <button class="chip ${state.screen === "tools" ? "active" : ""}" data-nav="tools">Инструменты</button>
        <button class="chip ${state.screen === "settings" ? "active" : ""}" data-nav="settings">Настройки</button>
      </div>
      <div class="legend">
        <div class="legend-item"><i></i><div><strong>Автомикс</strong> — бейдж на таймлайне, 5 актов DJ-истории</div></div>
        <div class="legend-item"><i style="background:#7dd3fc"></i><div><strong>DSP</strong> — Mid/Side stem, bass, HPF/LPF, echo</div></div>
        <div class="legend-item"><i style="background:#f0abfc"></i><div><strong>Ручная доводка</strong> — rates, bass swap, handoff</div></div>
      </div>
      <a class="link-lab" href="/">← Desktop Automix Lab</a>
    </aside>

    <div class="phone-wrap">
      <div class="phone" aria-label="iPhone 17 Pro Cosmic Orange">
        <div class="btn-silent"></div>
        <div class="btn-vol-up"></div>
        <div class="btn-vol-down"></div>
        <div class="btn-power"></div>
        <div class="screen">
          <div class="screen-bg ${bgTint}"></div>
          <div class="island" aria-hidden="true"></div>
          <div class="status-bar">
            <span>9:41</span>
            <span class="right">■■■ ▊ 🔋</span>
          </div>

          <div class="app">
            <div class="player-top">
              <button class="glass-btn" data-action="dismiss" aria-label="Свернуть">${icon("chevron")}</button>
              <span class="queue-pill">Моя волна</span>
              <button class="glass-btn" data-nav="settings" aria-label="Ещё">${icon("more")}</button>
            </div>

            <div class="artwork-stage ${artClass}">
              <img class="outgoing" src="/mock/cover-a.jpg" alt="Midnight Grid" />
              <img class="incoming" src="/mock/cover-b.jpg" alt="Neon Afterglow" />
            </div>

            <div class="meta">
              <h2>${trackTitle()}</h2>
              <div class="artist">${trackArtist()}</div>
              <div class="next">${
                state.mixing
                  ? `Далее · Neon Afterglow · ${phase || "…"}`
                  : "Далее · Neon Afterglow"
              }</div>
            </div>

            <div class="timeline-block">
              <div class="scrub"><div class="fill" style="width:${(state.progress * 100).toFixed(1)}%"></div></div>
              <div class="times-row">
                <span>${fmt(elapsed)}</span>
                <div class="mixing-badge ${state.mixing ? "on" : ""}">
                  <div class="title">Автомикс</div>
                  <div class="phase">${phase || " "}</div>
                </div>
                <span>-${fmt(Math.max(0, remaining))}</span>
              </div>
            </div>

            <div class="transport">
              <button class="side on" aria-label="Shuffle">${icon("shuffle")}</button>
              <button class="skip" aria-label="Prev">${icon("skipBack")}</button>
              <button class="play" data-action="play" aria-label="Play/Pause">${
                state.playing ? icon("pause") : icon("play")
              }</button>
              <button class="skip" aria-label="Next">${icon("skipFwd")}</button>
              <button class="side" aria-label="Repeat">${icon("repeat")}</button>
            </div>

            <div class="bottom-actions">
              <div class="left">
                <button class="glass-btn" aria-label="Избранное" style="color:var(--amber)">${icon("star")}</button>
                <button class="glass-btn" aria-label="Текст">${icon("quote")}</button>
              </div>
              <div class="right">
                <button class="glass-btn" data-nav="tools" aria-label="Automix tools" title="Automix">${icon("airplay")}</button>
                <button class="glass-btn" data-nav="settings" aria-label="Очередь">${icon("list")}</button>
              </div>
            </div>
            <div class="home-indicator"></div>
          </div>

          <div class="sheet ${state.screen === "tools" ? "open" : ""}" id="toolsSheet">
            <div class="sheet-handle"></div>
            <div class="sheet-head">
              <div>
                <h3>Automix</h3>
                <div class="sub">Инструменты сведения</div>
              </div>
              <button class="glass-btn" data-nav="player" aria-label="Закрыть" style="font-size:18px">✕</button>
            </div>
            <div class="sheet-scroll">
              <div class="phase-strip">
                ${PHASES.map(
                  (p, i) =>
                    `<span class="${state.phaseIdx === i && state.mixing ? "active" : ""}" data-phase="${i}">${p.replace(" ", "\n")}</span>`
                ).join("")}
              </div>

              <div class="section-label">Стемы · Mid/Side</div>
              <div class="tool-grid">
                <button class="tool-tile ${state.stems.instrA ? "on" : ""}" data-stem="instrA">
                  <div class="icon">▣</div>
                  <div class="name">A Instrumental</div>
                  <div class="blurb">Убрать вокал уходящего — karaoke Mid/Side</div>
                </button>
                <button class="tool-tile ${state.stems.vocalB ? "on" : ""}" data-stem="vocalB">
                  <div class="icon">◉</div>
                  <div class="name">B Vocal focus</div>
                  <div class="blurb">Сжать сайды, поднять mid presence</div>
                </button>
                <button class="tool-tile ${state.stems.hpf ? "on" : ""}" data-stem="hpf">
                  <div class="icon">↗</div>
                  <div class="name">HPF / LPF</div>
                  <div class="blurb">Riser на A, reveal на B</div>
                </button>
                <button class="tool-tile ${state.stems.echo ? "on" : ""}" data-stem="echo">
                  <div class="icon">〰</div>
                  <div class="name">Echo-out</div>
                  <div class="blurb">0.75 beat delay на хвосте A</div>
                </button>
              </div>

              <div class="section-label">Живые метры</div>
              <div class="meter-block">
                <div class="meter-row a">
                  <label><span>Instr A</span><span>${Math.round(stemMeter("instrA") * 100)}%</span></label>
                  <div class="track"><i style="width:${stemMeter("instrA") * 100}%"></i></div>
                </div>
                <div class="meter-row b">
                  <label><span>Vocal B</span><span>${Math.round(stemMeter("vocalB") * 100)}%</span></label>
                  <div class="track"><i style="width:${stemMeter("vocalB") * 100}%"></i></div>
                </div>
                <div class="meter-row a">
                  <label><span>Bass A kill</span><span>${Math.round(bassMeterA() * 100)}%</span></label>
                  <div class="track"><i style="width:${bassMeterA() * 100}%"></i></div>
                </div>
                <div class="meter-row b">
                  <label><span>Bass B</span><span>${Math.round(bassMeterB() * 100)}%</span></label>
                  <div class="track"><i style="width:${bassMeterB() * 100}%"></i></div>
                </div>
                <div class="meter-row a">
                  <label><span>Echo A</span><span>${Math.round(echoMeter() * 100)}%</span></label>
                  <div class="track"><i style="width:${echoMeter() * 100}%"></i></div>
                </div>
              </div>

              <div class="section-label">Ручная настройка</div>
              ${knobHTML("blend", "Окно сведения", state.knobs.blend, 8, 32, 0.5, (v) => `${v.toFixed(1)} с`)}
              ${knobHTML("bassSwap", "Bass lock", state.knobs.bassSwap, 0.1, 0.6, 0.01, (v) => v.toFixed(2))}
              ${knobHTML("handoff", "Handoff", state.knobs.handoff, 0.3, 0.8, 0.01, (v) => v.toFixed(2))}
              ${knobHTML("bassDepth", "Bass depth", state.knobs.bassDepth, 0.6, 1.6, 0.05, (v) => v.toFixed(2))}
              ${knobHTML("rateB", "Rate B", state.knobs.rateB, 0.9, 1.1, 0.001, (v) => v.toFixed(3))}

              <div class="cta-row">
                <button class="btn-primary" data-action="ai">✦ AI Auto Mix</button>
                <button class="btn-secondary" data-nav="settings">Переходы и режим…</button>
              </div>
              <div class="ai-note">
                AI сам ставит BPM, mixOut/mixIn и ведёт LOCK→LAND.
                Ручки выше — тонкая доводка на слух, как в Automix Lab.
              </div>
            </div>
          </div>

          <div class="view-settings ${state.screen === "settings" ? "open" : ""}">
            <button class="nav-back" data-nav="player">${icon("back")} Плеер</button>
            <h1>Переходы</h1>
            <div class="sheet-scroll">
              <div class="section-label">Режим</div>
              <div class="card-list">
                ${modeCard("gapless", "Gapless", "Без пауз между треками")}
                ${modeCard("crossfade", "Кроссфейд", "Плавное пересечение по длительности")}
                ${modeCard("automix", "AutoMix Mashup", "Beatmatch + вокал/инструментал на сетке; длительность без слайдера")}
                ${modeCard("off", "Выключено", "Стандартное раздельное воспроизведение")}
              </div>

              <div class="section-label">Automix</div>
              <div class="toggle-row">
                <div>
                  <div class="label">Включить Automix</div>
                  <div class="hint">Анализ current/next и мэшап на стыке</div>
                </div>
                <button class="ios-switch ${state.automixOn ? "on" : ""}" data-action="toggle-automix" aria-label="Automix"></button>
              </div>
              <div class="toggle-row">
                <div>
                  <div class="label">Instrumentalize outro A</div>
                  <div class="hint">Mid/Side удаление вокала на хвосте</div>
                </div>
                <button class="ios-switch ${state.stems.instrA ? "on" : ""}" data-stem="instrA"></button>
              </div>
              <div class="toggle-row">
                <div>
                  <div class="label">Vocal focus на B</div>
                  <div class="hint">Подчеркнуть вокал входящего в мэшапе</div>
                </div>
                <button class="ios-switch ${state.stems.vocalB ? "on" : ""}" data-stem="vocalB"></button>
              </div>
              <div class="toggle-row">
                <div>
                  <div class="label">Echo-out хвост</div>
                  <div class="hint">Tempo-sync delay при LAND</div>
                </div>
                <button class="ios-switch ${state.stems.echo ? "on" : ""}" data-stem="echo"></button>
              </div>

              <div class="section-label">Тонкая настройка</div>
              ${knobHTML("blend", "Окно сведения", state.knobs.blend, 8, 32, 0.5, (v) => `${v.toFixed(1)} с`)}
              ${knobHTML("bassSwap", "Bass lock at", state.knobs.bassSwap, 0.1, 0.6, 0.01, (v) => v.toFixed(2))}
              ${knobHTML("handoff", "Handoff at", state.knobs.handoff, 0.3, 0.8, 0.01, (v) => v.toFixed(2))}

              <div class="cta-row">
                <button class="btn-primary" data-nav="tools">Открыть инструменты</button>
                <button class="btn-secondary" data-action="demo">Проиграть демо-переход</button>
              </div>
            </div>
            <div class="home-indicator"></div>
          </div>
        </div>
      </div>
    </div>

    <aside class="side-copy right">
      <p style="font-size:13px;color:var(--ink-muted)">
        Корпус Cosmic Orange · Dynamic Island · 6.3″ Super Retina.<br/>
        Акцент Sonivo — amber, как в приложении.
      </p>
      <div class="chips">
        <button class="chip" data-action="demo">▶ Демо перехода</button>
        <button class="chip ${state.mixing ? "active" : ""}" data-action="toggle-mix">Mixing ${state.mixing ? "ON" : "OFF"}</button>
      </div>
    </aside>
  `;

  wire();
}

function modeCard(id: typeof state.transition, title: string, desc: string): string {
  const sel = state.transition === id;
  return `
    <div class="row-card ${sel ? "selected" : ""}" data-mode="${id}">
      <div>
        <div class="title">${title}</div>
        <div class="desc">${desc}</div>
      </div>
      <div class="check">✓</div>
    </div>`;
}

function knobHTML(
  key: keyof typeof state.knobs,
  label: string,
  value: number,
  min: number,
  max: number,
  step: number,
  format: (v: number) => string
): string {
  return `
    <div class="knob">
      <div class="top"><span>${label}</span><output>${format(value)}</output></div>
      <input type="range" data-knob="${key}" min="${min}" max="${max}" step="${step}" value="${value}" />
    </div>`;
}

function stemMeter(kind: "instrA" | "vocalB"): number {
  if (!state.mixing) return 0;
  const p = state.progress;
  if (kind === "instrA") {
    if (!state.stems.instrA) return 0;
    return Math.min(1, 0.2 + p * 1.1);
  }
  if (!state.stems.vocalB) return 0;
  return Math.min(1, 0.3 + p * 0.9);
}

function bassMeterA(): number {
  if (!state.mixing) return 0;
  return Math.min(1, state.progress / Math.max(0.01, state.knobs.bassSwap));
}

function bassMeterB(): number {
  if (!state.mixing) return 0;
  return Math.min(1, Math.max(0, (state.progress - state.knobs.bassSwap * 0.4) / 0.4));
}

function echoMeter(): number {
  if (!state.mixing || !state.stems.echo) return 0;
  if (state.progress < state.knobs.handoff - 0.1) return 0;
  return Math.min(1, (state.progress - (state.knobs.handoff - 0.1)) / 0.35);
}

function wire() {
  stage.querySelectorAll("[data-nav]").forEach((el) => {
    el.addEventListener("click", () => {
      demoRunning = false;
      cancelAnimationFrame(demoTimer);
      state.screen = (el.getAttribute("data-nav") as Screen) || "player";
      render();
    });
  });

  stage.querySelectorAll("[data-mode]").forEach((el) => {
    el.addEventListener("click", () => {
      state.transition = el.getAttribute("data-mode") as typeof state.transition;
      state.automixOn = state.transition === "automix";
      state.mixing = state.automixOn;
      render();
    });
  });

  stage.querySelectorAll("[data-stem]").forEach((el) => {
    el.addEventListener("click", () => {
      const k = el.getAttribute("data-stem") as keyof typeof state.stems;
      if (k in state.stems) state.stems[k] = !state.stems[k];
      render();
    });
  });

  stage.querySelectorAll("[data-phase]").forEach((el) => {
    el.addEventListener("click", () => {
      state.phaseIdx = Number(el.getAttribute("data-phase"));
      state.mixing = true;
      state.progress = [0.08, 0.18, 0.35, 0.55, 0.88][state.phaseIdx] ?? 0.5;
      render();
    });
  });

  stage.querySelectorAll<HTMLInputElement>("[data-knob]").forEach((input) => {
    input.addEventListener("input", () => {
      const k = input.dataset.knob as keyof typeof state.knobs;
      state.knobs[k] = Number(input.value);
      const out = input.parentElement?.querySelector("output");
      if (out) {
        if (k === "blend") out.textContent = `${state.knobs.blend.toFixed(1)} с`;
        else if (k === "rateB") out.textContent = state.knobs.rateB.toFixed(3);
        else out.textContent = state.knobs[k].toFixed(2);
      }
    });
  });

  stage.querySelectorAll("[data-action]").forEach((el) => {
    el.addEventListener("click", () => {
      const a = el.getAttribute("data-action");
      if (a === "play") {
        state.playing = !state.playing;
        render();
      } else if (a === "toggle-automix") {
        state.automixOn = !state.automixOn;
        state.transition = state.automixOn ? "automix" : "gapless";
        state.mixing = state.automixOn;
        render();
      } else if (a === "toggle-mix") {
        state.mixing = !state.mixing;
        render();
      } else if (a === "ai" || a === "demo") {
        startDemo();
      } else if (a === "dismiss") {
        state.screen = "player";
        render();
      }
    });
  });
}

let demoTimer = 0;
let demoRunning = false;

function patchLiveUI() {
  const phase = phaseLabel();
  const fill = stage.querySelector<HTMLDivElement>(".scrub .fill");
  if (fill) fill.style.width = `${(state.progress * 100).toFixed(1)}%`;

  const badge = stage.querySelector(".mixing-badge");
  if (badge) {
    badge.classList.toggle("on", state.mixing);
    const phaseEl = badge.querySelector(".phase");
    if (phaseEl) phaseEl.textContent = phase || " ";
  }

  const art = stage.querySelector(".artwork-stage");
  if (art) art.className = `artwork-stage ${artworkClass()}`;

  const bg = stage.querySelector(".screen-bg");
  if (bg) {
    bg.classList.toggle("b-tint", artworkClass() === "land" || phase === "LAND");
  }

  const title = stage.querySelector(".meta h2");
  const artist = stage.querySelector(".meta .artist");
  const next = stage.querySelector(".meta .next");
  if (title) title.textContent = trackTitle();
  if (artist) artist.textContent = trackArtist();
  if (next) {
    next.textContent = state.mixing
      ? `Далее · Neon Afterglow · ${phase || "…"}`
      : "Далее · Neon Afterglow";
  }

  const elapsed = 148 + state.progress * 16;
  const remaining = 210 - elapsed;
  const times = stage.querySelectorAll(".times-row > span");
  if (times[0]) times[0].textContent = fmt(elapsed);
  if (times[1]) times[1].textContent = `-${fmt(Math.max(0, remaining))}`;

  stage.querySelectorAll(".phase-strip span").forEach((el, i) => {
    el.classList.toggle("active", state.phaseIdx === i && state.mixing);
  });

  // Update meters if tools sheet is open
  const meters = [
    ["Instr A", stemMeter("instrA")],
    ["Vocal B", stemMeter("vocalB")],
    ["Bass A kill", bassMeterA()],
    ["Bass B", bassMeterB()],
    ["Echo A", echoMeter()],
  ] as const;
  stage.querySelectorAll(".meter-row").forEach((row, i) => {
    const m = meters[i];
    if (!m) return;
    const labelPct = row.querySelector("label span:last-child");
    const bar = row.querySelector<HTMLElement>(".track > i");
    if (labelPct) labelPct.textContent = `${Math.round(m[1] * 100)}%`;
    if (bar) bar.style.width = `${m[1] * 100}%`;
  });
}

function startDemo() {
  cancelAnimationFrame(demoTimer);
  demoRunning = true;
  state.screen = "player";
  state.mixing = true;
  state.playing = true;
  state.automixOn = true;
  state.transition = "automix";
  state.progress = 0;
  state.phaseIdx = 0;
  render();

  const t0 = performance.now();
  const dur = 10000;
  const tick = (now: number) => {
    if (!demoRunning) return;
    const t = Math.min(1, (now - t0) / dur);
    state.progress = t;
    if (t < 0.12) state.phaseIdx = 0;
    else if (t < 0.22) state.phaseIdx = 1;
    else if (t < state.knobs.handoff) state.phaseIdx = 2;
    else if (t < 0.82) state.phaseIdx = 3;
    else state.phaseIdx = 4;
    patchLiveUI();
    if (t < 1) demoTimer = requestAnimationFrame(tick);
    else demoRunning = false;
  };
  demoTimer = requestAnimationFrame(tick);
}

render();
startDemo();
