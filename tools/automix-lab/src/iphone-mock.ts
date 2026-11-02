import "./iphone-mock.css";

/**
 * iPhone 17 Pro Cosmic Orange mock:
 * official SVG chassis + live Sonivo screen (same UI as /).
 *
 * Frame: jamesjingyi/mockup-device-frames · 17 Pro Cosmic Orange
 * viewBox 1406×2822 · screen 1206×2622 @ (100,100)
 */
const FRAME_W = 1406;
const FRAME_H = 2822;
const SCREEN_X = 100;
const SCREEN_Y = 100;
const SCREEN_W = 1206;
const SCREEN_H = 2622;
const SCREEN_RADIUS = 168;

const stage = document.querySelector<HTMLDivElement>("#stage")!;

stage.innerHTML = `
  <aside class="copy">
    <p class="eyebrow">iPhone 17 Pro · Cosmic Orange</p>
    <h1>Так приложение<br/><em>выглядит на телефоне</em></h1>
    <p class="lede">
      Корпус — настоящий SVG iPhone&nbsp;17&nbsp;Pro Cosmic&nbsp;Orange.
      Экран внутри — живой плеер с
      <a href="/">главной</a>, без статичной картинки.
    </p>
    <ul class="meta">
      <li><strong>Device</strong> iPhone 17 Pro</li>
      <li><strong>Color</strong> Cosmic Orange</li>
      <li><strong>Screen</strong> live UI 1206×2622</li>
    </ul>
    <div class="actions">
      <a class="btn" href="/">Открыть плеер</a>
      <button type="button" class="btn ghost" id="btnReload">Обновить экран</button>
    </div>
  </aside>

  <div class="phone-stage">
    <div
      class="phone"
      style="--fw:${FRAME_W};--fh:${FRAME_H};--sx:${SCREEN_X};--sy:${SCREEN_Y};--sw:${SCREEN_W};--sh:${SCREEN_H};--sr:${SCREEN_RADIUS}"
      aria-label="iPhone 17 Pro Cosmic Orange"
    >
      <img
        class="frame"
        src="/mock/iphone-17-pro-cosmic-orange.svg"
        width="${FRAME_W}"
        height="${FRAME_H}"
        alt="iPhone 17 Pro Cosmic Orange"
        draggable="false"
      />
      <div class="screen">
        <iframe
          id="playerFrame"
          title="Sonivo Automix на iPhone 17 Pro"
          src="/"
          loading="eager"
          allow="autoplay; encrypted-media"
        ></iframe>
      </div>
    </div>
  </div>
`;

document.querySelector("#btnReload")?.addEventListener("click", () => {
  const frame = document.querySelector<HTMLIFrameElement>("#playerFrame");
  if (frame) frame.src = `/?mock=${Date.now()}`;
});
