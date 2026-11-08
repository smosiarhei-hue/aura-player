import "./iphone-mock.css";

/**
 * iPhone 17 Pro Cosmic Orange mock with a correctly sized live screen.
 *
 * SVG viewBox 1406×2822; display hole 1206×2622 @ (100,100) after
 * group translate(45 53)+translate(8 -1). Dynamic Island in SVG is under
 * the glass fill, so we paint a matching CSS island over the iframe.
 *
 * Screen is laid out at real iPhone CSS points (402×874) so the player
 * does not center a 430px stage inside an oversized iframe.
 */
const FRAME_W = 1406;
const FRAME_H = 2822;
const HOLE_X = 100;
const HOLE_Y = 100;
const HOLE_W = 1206;
/** Logical CSS points for iPhone 17 Pro. */
const SCREEN_PT_W = 402;
const SCREEN_PT_H = 874;
const UNIT = SCREEN_PT_W / HOLE_W;
const FRAME_PX_W = FRAME_W * UNIT;
const FRAME_PX_H = FRAME_H * UNIT;
const SCREEN_X = HOLE_X * UNIT;
const SCREEN_Y = HOLE_Y * UNIT;
/** Continuous-corner approx of the glass hole (~236 SVG units). */
const SCREEN_RADIUS = 236 * UNIT;
/**
 * Island: SVG translate(470 87) under body translate(45 53) → (515, 140),
 * size 378×110 in SVG units.
 */
const ISLAND_X = (515 - HOLE_X) * UNIT;
const ISLAND_Y = (140 - HOLE_Y) * UNIT;
const ISLAND_W = 378 * UNIT;
const ISLAND_H = 110 * UNIT;

const stage = document.querySelector<HTMLDivElement>("#stage")!;

stage.innerHTML = `
  <aside class="copy">
    <p class="eyebrow">iPhone 17 Pro · Cosmic Orange</p>
    <h1>Так приложение<br/><em>выглядит на телефоне</em></h1>
    <p class="lede">
      Корпус — SVG Cosmic&nbsp;Orange. Экран —
      ${SCREEN_PT_W}×${SCREEN_PT_H}&nbsp;pt с живым плеером
      <a href="/">как на главной</a>.
    </p>
    <ul class="meta">
      <li><strong>Device</strong> iPhone 17 Pro</li>
      <li><strong>Color</strong> Cosmic Orange</li>
      <li><strong>Viewport</strong> ${SCREEN_PT_W}×${SCREEN_PT_H} pt</li>
    </ul>
    <div class="actions">
      <a class="btn" href="/">Открыть плеер</a>
      <button type="button" class="btn ghost" id="btnReload">Обновить экран</button>
    </div>
  </aside>

  <div class="phone-stage">
    <div
      class="phone-fit"
      style="--phone-w:${FRAME_PX_W}px;--phone-h:${FRAME_PX_H}px;--screen-x:${SCREEN_X}px;--screen-y:${SCREEN_Y}px;--screen-w:${SCREEN_PT_W}px;--screen-h:${SCREEN_PT_H}px;--screen-r:${SCREEN_RADIUS}px;--island-x:${ISLAND_X}px;--island-y:${ISLAND_Y}px;--island-w:${ISLAND_W}px;--island-h:${ISLAND_H}px"
    >
      <div class="phone" aria-label="iPhone 17 Pro Cosmic Orange">
        <div class="screen">
          <iframe
            id="playerFrame"
            title="Sonivo Automix на iPhone 17 Pro"
            src="/?embed=phone"
            loading="eager"
            allow="autoplay; encrypted-media"
          ></iframe>
          <div class="island" aria-hidden="true"></div>
        </div>
        <img
          class="frame"
          src="/mock/iphone-17-pro-cosmic-orange.svg"
          width="${FRAME_W}"
          height="${FRAME_H}"
          alt=""
          draggable="false"
        />
      </div>
    </div>
  </div>
`;

document.querySelector("#btnReload")?.addEventListener("click", () => {
  const frame = document.querySelector<HTMLIFrameElement>("#playerFrame");
  if (frame) frame.src = `/?embed=phone&t=${Date.now()}`;
});
