/**
 * Emits a standalone hook's own website into its repository.
 *
 * A spun-out repository has to be able to build and publish its site with nothing installed, so what lands in `web/`
 * is a build script with no dependencies, a stylesheet, and one ES module that pulls three.js from a pinned CDN
 * through an import map. The social card is rasterised here, where a rasteriser is available, and committed as a
 * static asset.
 *
 * The page itself is server-rendered HTML. The 3D scene is decoration over content that is already complete: with
 * JavaScript disabled, or WebGL unavailable, the page still says everything it has to say.
 */
import {existsSync, mkdirSync, readFileSync, writeFileSync} from "node:fs";
import {execFileSync} from "node:child_process";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

import {claimedFlags, errorTable, flagMask, paragraphs, parameterTable} from "./templates.mjs";
import {hookCard} from "../../apps/web/lib/og.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

const THREE_VERSION = "0.170.0";
const THREE_CDN = `https://cdn.jsdelivr.net/npm/three@${THREE_VERSION}/build/three.module.js`;

function write(root, path, contents) {
  const full = join(root, path);
  mkdirSync(dirname(full), {recursive: true});
  writeFileSync(full, contents);
}

const SCENE = `/**
 * The pool, in three dimensions.
 *
 * A Uniswap v4 pool is a curve with fourteen doors around it, and this draws exactly that: the torus is the pool, the
 * fourteen pillars are the callbacks the protocol offers, and the ones this hook claims stand tall and lit while the
 * rest stay dark and low. Order flow orbits the curve as particles and slows where a lit pillar governs it, which is
 * the picture of a hook pricing a swap on its way through.
 *
 * Drag to orbit. It rotates on its own when left alone, pauses when scrolled out of view, and renders one still frame
 * when the visitor has asked for reduced motion. Without WebGL the page loses the picture and nothing else: every fact
 * it shows is also written in the text beneath it.
 */
import {
  AdditiveBlending, BufferAttribute, BufferGeometry, CanvasTexture, Color, CylinderGeometry, Fog, Group, Mesh,
  MeshBasicMaterial, PerspectiveCamera, Points, PointsMaterial, Scene, SphereGeometry, Sprite, SpriteMaterial,
  TorusGeometry, WebGLRenderer,
} from "three";

/** The fourteen callbacks, grouped so a phase reads as a contiguous arc of the ring. */
const DOORS = [
  ["beforeInitialize", "init"], ["afterInitialize", "init"],
  ["beforeAddLiquidity", "liquidity"], ["afterAddLiquidity", "liquidity"],
  ["afterAddLiquidityReturnsDelta", "liquidity"],
  ["beforeRemoveLiquidity", "liquidity"], ["afterRemoveLiquidity", "liquidity"],
  ["afterRemoveLiquidityReturnsDelta", "liquidity"],
  ["beforeSwap", "swap"], ["afterSwap", "swap"],
  ["beforeSwapReturnsDelta", "swap"], ["afterSwapReturnsDelta", "swap"],
  ["beforeDonate", "donate"], ["afterDonate", "donate"],
];

const PHASE = {init: 0x8ab4ff, liquidity: 0x4ecdc4, swap: 0xff6a2b, donate: 0xb58cff};

const canvas = document.querySelector("canvas[data-permissions]");
if (canvas) mount(canvas, JSON.parse(canvas.dataset.permissions));

function label(text, active) {
  const c = document.createElement("canvas");
  const scale = 3;
  c.width = 340 * scale;
  c.height = 52 * scale;
  const ctx = c.getContext("2d");
  ctx.scale(scale, scale);
  ctx.font = "500 17px ui-monospace, SFMono-Regular, Menlo, monospace";
  ctx.fillStyle = active ? "#e8eaef" : "#4b5563";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, 170, 26);
  const sprite = new Sprite(new SpriteMaterial({map: new CanvasTexture(c), transparent: true, depthTest: false}));
  sprite.scale.set(2.5, 0.38, 1);
  return sprite;
}

function mount(canvas, permissions) {
  let renderer;
  try {
    renderer = new WebGLRenderer({canvas, antialias: true, alpha: true, powerPreference: "high-performance"});
  } catch {
    return;
  }

  const fallback = canvas.parentElement?.querySelector(".scene__fallback");
  if (fallback) fallback.classList.add("scene__fallback--quiet");

  const scene = new Scene();
  scene.fog = new Fog(0x07080b, 12, 30);

  const camera = new PerspectiveCamera(42, 1, 0.1, 120);
  const root = new Group();
  scene.add(root);

  const RADIUS = 3.2;

  // The pool: the curve every swap moves along.
  const ring = new Mesh(
    new TorusGeometry(RADIUS, 0.045, 14, 260),
    new MeshBasicMaterial({color: 0x1d6f74, transparent: true, opacity: 0.9}),
  );
  ring.rotation.x = Math.PI / 2;
  root.add(ring);

  const halo = new Mesh(
    new TorusGeometry(RADIUS, 0.24, 12, 200),
    new MeshBasicMaterial({color: 0x1d6f74, transparent: true, opacity: 0.06, blending: AdditiveBlending}),
  );
  halo.rotation.x = Math.PI / 2;
  root.add(halo);

  // A faint floor ring, purely to give the eye a horizon and make the ring read as a solid in space.
  const floor = new Mesh(
    new TorusGeometry(RADIUS * 1.9, 0.006, 6, 160),
    new MeshBasicMaterial({color: 0x1b1f28, transparent: true, opacity: 0.7}),
  );
  floor.rotation.x = Math.PI / 2;
  floor.position.y = -1.5;
  root.add(floor);

  const doors = DOORS.map(([key, phase], index) => {
    const active = permissions[key] === true;
    const angle = (index / DOORS.length) * Math.PI * 2;
    const height = active ? 1.5 : 0.34;
    const colour = new Color(active ? PHASE[phase] : 0x252c38);

    const pillar = new Mesh(
      new CylinderGeometry(active ? 0.075 : 0.05, active ? 0.075 : 0.05, height, 14),
      new MeshBasicMaterial({color: colour, transparent: true, opacity: active ? 0.95 : 0.5}),
    );
    pillar.position.set(Math.cos(angle) * RADIUS, height / 2, Math.sin(angle) * RADIUS);
    root.add(pillar);

    let glow = null;
    if (active) {
      glow = new Mesh(
        new SphereGeometry(0.2, 18, 14),
        new MeshBasicMaterial({color: colour, transparent: true, opacity: 0.25, blending: AdditiveBlending}),
      );
      glow.position.set(pillar.position.x, height, pillar.position.z);
      root.add(glow);
    }

    const text = label(key, active);
    text.position.set(Math.cos(angle) * (RADIUS + 1.55), height + 0.34, Math.sin(angle) * (RADIUS + 1.55));
    root.add(text);

    return {angle, active, pillar, glow, height};
  });

  // Order flow, orbiting the curve. It slows in the arc a claimed callback governs, which is what a hook taxing a
  // swap on its way through actually looks like.
  const COUNT = 1400;
  const positions = new Float32Array(COUNT * 3);
  const phase = new Float32Array(COUNT);
  const lift = new Float32Array(COUNT);
  for (let i = 0; i < COUNT; i++) {
    phase[i] = Math.random() * Math.PI * 2;
    lift[i] = (Math.random() - 0.5) * 0.3;
  }
  const geometry = new BufferGeometry();
  geometry.setAttribute("position", new BufferAttribute(positions, 3));
  const flow = new Points(
    geometry,
    new PointsMaterial({color: 0x7fe9d8, size: 0.05, transparent: true, opacity: 0.8, blending: AdditiveBlending}),
  );
  root.add(flow);

  // Camera, orbited by dragging and drifting on its own otherwise.
  let yaw = 0.6;
  let pitch = 0.52;
  let targetYaw = yaw;
  let targetPitch = pitch;
  let distance = 11.5;
  let dragging = false;
  let lastPointer = null;
  let idleSince = performance.now();

  canvas.style.touchAction = "pan-y";
  canvas.addEventListener("pointerdown", (event) => {
    dragging = true;
    lastPointer = {x: event.clientX, y: event.clientY};
    canvas.setPointerCapture(event.pointerId);
    canvas.style.cursor = "grabbing";
  });
  canvas.addEventListener("pointermove", (event) => {
    if (!dragging || !lastPointer) return;
    targetYaw -= (event.clientX - lastPointer.x) * 0.006;
    targetPitch = Math.max(0.12, Math.min(1.3, targetPitch + (event.clientY - lastPointer.y) * 0.004));
    lastPointer = {x: event.clientX, y: event.clientY};
    idleSince = performance.now();
  });
  const release = (event) => {
    dragging = false;
    lastPointer = null;
    canvas.style.cursor = "grab";
    idleSince = performance.now();
    if (event?.pointerId !== undefined && canvas.hasPointerCapture(event.pointerId)) {
      canvas.releasePointerCapture(event.pointerId);
    }
  };
  canvas.addEventListener("pointerup", release);
  canvas.addEventListener("pointercancel", release);
  canvas.style.cursor = "grab";

  function resize() {
    const {clientWidth, clientHeight} = canvas;
    if (clientWidth === 0 || clientHeight === 0) return;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(clientWidth, clientHeight, false);
    camera.aspect = clientWidth / clientHeight;
    // Pull back on narrow screens so the ring and its labels still fit.
    distance = clientWidth < 720 ? 15.5 : 11.5;
    camera.updateProjectionMatrix();
  }

  const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
  let elapsed = 0;
  let last = performance.now();
  let visible = true;

  function step(delta, now) {
    elapsed += delta;

    // Drift back into motion once the visitor has stopped dragging.
    if (!dragging && now - idleSince > 2500) targetYaw += delta * 0.12;
    yaw += (targetYaw - yaw) * 0.08;
    pitch += (targetPitch - pitch) * 0.08;

    camera.position.set(
      Math.sin(yaw) * Math.cos(pitch) * distance,
      Math.sin(pitch) * distance,
      Math.cos(yaw) * Math.cos(pitch) * distance,
    );
    camera.lookAt(0, 0.4, 0);

    for (const door of doors) {
      if (!door.active) continue;
      const pulse = 0.5 + 0.5 * Math.sin(elapsed * 1.6 + door.angle * 2.4);
      door.pillar.scale.y = 1 + pulse * 0.06;
      if (door.glow) {
        door.glow.material.opacity = 0.16 + pulse * 0.24;
        door.glow.scale.setScalar(1 + pulse * 0.22);
      }
    }

    for (let i = 0; i < COUNT; i++) {
      let drag = 0;
      for (const door of doors) {
        if (!door.active) continue;
        const gap = Math.abs(((phase[i] - door.angle + Math.PI * 3) % (Math.PI * 2)) - Math.PI);
        if (gap > Math.PI - 0.5) drag += 1;
      }
      phase[i] += delta * 0.34 / (1 + drag * 2.2);
      const r = RADIUS + Math.sin(phase[i] * 4 + i) * 0.06;
      positions[i * 3] = Math.cos(phase[i]) * r;
      positions[i * 3 + 1] = lift[i] + Math.sin(elapsed * 0.7 + i) * 0.03;
      positions[i * 3 + 2] = Math.sin(phase[i]) * r;
    }
    flow.geometry.attributes.position.needsUpdate = true;
  }

  resize();
  if (reduced) {
    step(0, performance.now());
    renderer.render(scene, camera);
  } else {
    const frame = (now) => {
      requestAnimationFrame(frame);
      const delta = Math.min((now - last) / 1000, 0.05);
      last = now;
      if (!visible) return;
      step(delta, now);
      renderer.render(scene, camera);
    };
    requestAnimationFrame(frame);
  }

  window.addEventListener("resize", resize, {passive: true});
  new IntersectionObserver((entries) => {
    visible = entries.some((entry) => entry.isIntersecting);
  }).observe(canvas);
}

// Copy buttons, for the addresses and commands this page exists to hand people.
document.addEventListener("click", async (event) => {
  const button = event.target.closest(".copy");
  if (!button || !navigator.clipboard) return;
  const value = button.dataset.copy ?? button.previousElementSibling?.textContent ?? "";
  await navigator.clipboard.writeText(value);
  const previous = button.textContent;
  button.textContent = "copied";
  setTimeout(() => { button.textContent = previous; }, 1400);
});
`;

const CSS = `/* One hook, one page. Dark because the scene is lit and a light theme behind it reads wrong. */
:root {
  color-scheme: dark;
  --ink: #07080b; --ink-raised: #0d0f14; --ink-sunken: #050609;
  --line: #1b1f28; --line-bright: #2a303c;
  --text: #e8eaef; --text-dim: #9aa3b2; --text-faint: #868e9c;
  --forge: #ff6a2b; --forge-soft: #ff8a52; --forge-glow: rgba(255, 106, 43, 0.12);
  --radius: 10px; --radius-lg: 16px;
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  --font: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Inter, Roboto, sans-serif;
}
*, *::before, *::after { box-sizing: border-box; }
@media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation-duration: .01ms !important; transition-duration: .01ms !important; } }
body { margin: 0; background: var(--ink); color: var(--text); font-family: var(--font); font-size: 16px; line-height: 1.65; -webkit-font-smoothing: antialiased; }
.shell { max-width: 940px; margin: 0 auto; padding-inline: clamp(1rem, 4vw, 2.25rem); }
a { color: var(--forge); text-decoration-color: rgba(255,106,43,.4); text-underline-offset: .2em; }
a:hover { color: var(--forge-soft); text-decoration-color: currentColor; }
a:focus-visible, button:focus-visible { outline: 2px solid var(--forge); outline-offset: 3px; border-radius: 4px; }
h1, h2, h3 { line-height: 1.2; letter-spacing: -.02em; margin: 0 0 .5em; font-weight: 640; text-wrap: balance; }
h1 { font-size: clamp(2.2rem, 6vw, 3.4rem); }
h2 { font-size: clamp(1.4rem, 3vw, 1.85rem); margin-top: 2.6em; }
h3 { font-size: 1.1rem; margin-top: 1.8em; }
p, li { text-wrap: pretty; }
p { margin: 0 0 1.1em; }
code, pre { font-family: var(--mono); font-size: .9em; }
code:not(pre code) { background: var(--ink-sunken); border: 1px solid var(--line); border-radius: 5px; padding: .12em .4em; }
pre { background: var(--ink-sunken); border: 1px solid var(--line); border-radius: var(--radius); padding: 1rem 1.15rem; overflow-x: auto; margin: 0 0 1.4em; line-height: 1.55; }
pre code { white-space: pre; background: none; border: 0; padding: 0; }
.skip { position: absolute; left: -9999px; }
.skip:focus { left: 1rem; top: 1rem; position: fixed; z-index: 100; background: var(--forge); color: #14060a; padding: .6rem 1rem; border-radius: var(--radius); }
.masthead { border-bottom: 1px solid var(--line); position: sticky; top: 0; z-index: 20; backdrop-filter: blur(14px); background: rgba(7,8,11,.82); }
.masthead__inner { display: flex; align-items: center; gap: 1.25rem; padding: .8rem 0; }
.masthead nav { margin-left: auto; display: flex; gap: 1.2rem; flex-wrap: wrap; }
.masthead a { color: var(--text-dim); text-decoration: none; font-size: .92rem; }
.masthead a:hover { color: var(--text); }
.brand { font-weight: 680; letter-spacing: -.03em; color: var(--text); text-decoration: none; }
.hero { padding: clamp(3rem, 8vw, 5rem) 0 1rem; }
.eyebrow { display: inline-flex; align-items: center; gap: .5rem; font-family: var(--mono); font-size: .72rem; letter-spacing: .12em; text-transform: uppercase; color: var(--forge); background: var(--forge-glow); border: 1px solid rgba(255,106,43,.3); border-radius: 999px; padding: .3rem .75rem; margin: 0 0 1.25rem; }
.lede { font-size: clamp(1.05rem, 2vw, 1.25rem); color: var(--text-dim); max-width: 60ch; }
.cta-row { display: flex; flex-wrap: wrap; gap: .7rem; margin: 1.75rem 0 0; }
.btn { display: inline-flex; align-items: center; gap: .5rem; padding: .6rem 1.1rem; border-radius: var(--radius); border: 1px solid var(--line-bright); background: var(--ink-raised); color: var(--text); text-decoration: none; font-size: .92rem; font-weight: 520; transition: transform .15s, border-color .15s; }
.btn:hover { transform: translateY(-1px); border-color: var(--forge); color: var(--text); }
.btn--primary { background: var(--forge); border-color: var(--forge); color: #14060a; font-weight: 600; }
.btn--primary:hover { background: var(--forge-soft); border-color: var(--forge-soft); color: #14060a; }
/* The scene is the page's backdrop, not a figure inside it: it fills the viewport and the hero copy sits over it. */
.stage { position: relative; min-height: min(88vh, 820px); display: grid; align-items: end; overflow: hidden; border-bottom: 1px solid var(--line); }
.scene { position: absolute; inset: 0; z-index: 0; }
.scene canvas { display: block; width: 100%; height: 100%; }
.scene__fallback { position: absolute; inset: auto 0 1rem; display: grid; place-items: center; padding: 1.5rem; margin: 0; text-align: center; color: var(--text-dim); font-size: .92rem; }
.scene__fallback--quiet { display: none; }
.scene__hint { position: absolute; right: 1rem; bottom: 1rem; z-index: 2; font-family: var(--mono); font-size: .72rem; color: var(--text-faint); pointer-events: none; }
/* A vignette so type over the scene stays readable wherever the camera happens to be. */
.stage::after { content: ""; position: absolute; inset: 0; z-index: 1; pointer-events: none; background: linear-gradient(to top, var(--ink) 2%, rgba(7,8,11,.72) 34%, rgba(7,8,11,.15) 62%, rgba(7,8,11,.55) 100%); }
.stage .hero { position: relative; z-index: 2; padding-bottom: clamp(2.5rem, 6vw, 4.5rem); }
@media (max-width: 720px) { .stage { min-height: min(78vh, 640px); } }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 1px; background: var(--line); border: 1px solid var(--line); border-radius: var(--radius-lg); overflow: hidden; margin: 2rem 0 0; }
.stat { background: var(--ink-raised); padding: 1.05rem 1.2rem; }
.stat dt { font-size: .72rem; letter-spacing: .08em; text-transform: uppercase; color: var(--text-faint); margin-bottom: .25rem; }
.stat dd { margin: 0; font-size: 1.05rem; font-weight: 600; }
.callout { border: 1px solid var(--line); border-left: 3px solid var(--line-bright); border-radius: var(--radius); background: var(--ink-raised); padding: 1rem 1.15rem; margin: 0 0 1.6em; }
.callout h3 { margin: 0 0 .6rem; font-size: .74rem; text-transform: uppercase; letter-spacing: .09em; color: var(--text-faint); }
.callout p:last-child { margin-bottom: 0; }
.callout--prior { border-left-color: var(--forge); }
.callout--warn { border-left-color: #ff6b8a; }
table { width: 100%; border-collapse: collapse; font-size: .9rem; margin: 0 0 1.6em; display: block; overflow-x: auto; }
th { text-align: left; font-weight: 560; font-size: .72rem; letter-spacing: .07em; text-transform: uppercase; color: var(--text-faint); padding: .5rem .75rem .5rem 0; border-bottom: 1px solid var(--line-bright); white-space: nowrap; }
td { padding: .6rem .75rem .6rem 0; border-bottom: 1px solid var(--line); vertical-align: top; }
tr:last-child td { border-bottom: 0; }
.flags { display: flex; flex-wrap: wrap; gap: .35rem; padding: 0; margin: 0 0 1.5em; list-style: none; }
.flag { font-family: var(--mono); font-size: .74rem; padding: .16rem .45rem; border-radius: 5px; border: 1px solid var(--line); color: var(--text-faint); background: var(--ink-sunken); }
.flag--on { color: var(--forge-soft); border-color: rgba(255,106,43,.4); background: var(--forge-glow); }
.copy { font-family: var(--font); font-size: .72rem; margin-left: .5rem; padding: .1rem .45rem; border-radius: 5px; border: 1px solid var(--line-bright); background: var(--ink-raised); color: var(--text-dim); cursor: pointer; }
.copy:hover { color: var(--text); border-color: var(--forge); }
.foot { border-top: 1px solid var(--line); margin-top: 4rem; padding: 2rem 0 3rem; color: var(--text-faint); font-size: .9rem; }
.foot a { color: var(--text-dim); text-decoration: none; }
.foot a:hover { color: var(--forge); }

/* ---------- the demo ---------- */
.demo { margin: 1.5rem 0 2rem; }
.panel { border: 1px solid var(--line); border-radius: var(--radius-lg); background: var(--ink-raised); overflow: hidden; }
.panel--empty { padding: 2rem 1.25rem; text-align: center; color: var(--text-dim); }
.panel__wallet { display: flex; align-items: center; gap: .75rem; padding: .7rem 1.1rem; border-bottom: 1px solid var(--line); font-size: .88rem; flex-wrap: wrap; }
.panel__chain { font-family: var(--mono); font-size: .78rem; color: var(--text-faint); border: 1px solid var(--line-bright); border-radius: 999px; padding: .15rem .6rem; }
.panel__account { font-family: var(--mono); font-size: .82rem; color: var(--text-dim); }
.panel__error { color: #ff8fa3; font-size: .82rem; }
.panel__body { padding: 1.25rem; }
.panel__head h3 { margin: 0 0 .3rem; font-size: 1.05rem; }
.panel__lede { margin: 0 0 1.1rem; color: var(--text-dim); font-size: .92rem; }
.panel__actions { display: flex; flex-wrap: wrap; gap: .6rem; align-items: center; margin: 1.1rem 0 .4rem; }
.panel__balance { font-family: var(--mono); font-size: .8rem; color: var(--text-faint); margin-left: auto; }
.panel__hint { color: var(--text-faint); font-size: .86rem; }
.btn--small { padding: .3rem .7rem; font-size: .82rem; }
.kv { display: grid; gap: .35rem; margin: 0 0 1rem; }
.kv__row { display: flex; justify-content: space-between; gap: 1rem; font-size: .88rem; border-bottom: 1px solid var(--line); padding-bottom: .35rem; }
.kv__row:last-child { border-bottom: 0; }
.kv__key { color: var(--text-faint); }
.kv__value { text-align: right; word-break: break-word; }
.kv__value--mono { font-family: var(--mono); font-size: .84rem; }
.raw { margin: 1rem 0; }
.raw summary { cursor: pointer; color: var(--text-dim); font-size: .88rem; }
.raw summary:hover { color: var(--text); }
.code { margin-top: .75rem; }
.status { display: flex; align-items: center; gap: .5rem; font-size: .88rem; min-height: 1.6rem; margin: .6rem 0 0; color: var(--text-dim); }
.status__dot { width: 8px; height: 8px; border-radius: 50%; background: var(--text-faint); flex: none; }
.status--pending .status__dot { background: var(--forge); animation: pulse 1s ease-in-out infinite; }
.status--ok .status__dot { background: #4ecdc4; }
.status--error { color: #ff8fa3; }
.status--error .status__dot { background: #ff6b8a; }
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: .3; } }
.compare { margin-top: 1.25rem; }
.compare__hint { color: var(--text-faint); font-size: .86rem; margin: 0; }
.compare__grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1px; background: var(--line); border: 1px solid var(--line); border-radius: var(--radius); overflow: hidden; }
.compare__cell { background: var(--ink-sunken); padding: .9rem 1rem; display: grid; gap: .2rem; }
.compare__cell--win { background: var(--forge-glow); }
.compare__label { font-size: .74rem; letter-spacing: .07em; text-transform: uppercase; color: var(--text-faint); }
.compare__value { font-size: 1.4rem; font-weight: 640; font-variant-numeric: tabular-nums; }
.field { display: grid; gap: .3rem; margin: 1rem 0; }
.field__label { font-size: .8rem; color: var(--text-dim); }
.field__hint { font-size: .78rem; color: var(--text-faint); }
.input { background: var(--ink-sunken); border: 1px solid var(--line-bright); border-radius: var(--radius); padding: .55rem .75rem; color: var(--text); font: inherit; font-family: var(--mono); font-size: .9rem; }
.input:focus { outline: 2px solid var(--forge); outline-offset: 1px; }
.warn { color: #ffc44d; font-size: .85rem; border-left: 2px solid #ffc44d; padding-left: .7rem; }
.modal { position: fixed; inset: 0; z-index: 100; background: rgba(3,4,6,.7); backdrop-filter: blur(3px); display: grid; place-items: center; padding: 1rem; }
.modal__panel { background: var(--ink-raised); border: 1px solid var(--line-bright); border-radius: var(--radius-lg); max-width: 520px; width: 100%; max-height: 90vh; overflow-y: auto; }
.modal__head { display: flex; align-items: center; justify-content: space-between; padding: 1rem 1.15rem; border-bottom: 1px solid var(--line); }
.modal__head h3 { margin: 0; font-size: 1rem; }
.modal__close { background: none; border: 0; color: var(--text-faint); font-size: 1.4rem; line-height: 1; cursor: pointer; padding: 0 .25rem; }
.modal__close:hover { color: var(--text); }
.modal__body { padding: 1.15rem; }
.modal__lede { color: var(--text-dim); font-size: .9rem; margin-top: 0; }
.modal__actions { display: flex; gap: .6rem; justify-content: flex-end; padding: 1rem 1.15rem; border-top: 1px solid var(--line); }

.headline { display: grid; gap: .2rem; margin: 0 0 1.25rem; }
.headline__value { font-size: clamp(2.4rem, 7vw, 3.6rem); font-weight: 660; letter-spacing: -.03em; line-height: 1; font-variant-numeric: tabular-nums; color: var(--forge); }
.headline__label { color: var(--text-dim); font-size: .92rem; }
.chart { margin: 0 0 1.25rem; }
.chart__svg svg { width: 100%; height: auto; display: block; }
.chart__caption { color: var(--text-faint); font-size: .8rem; margin-top: .4rem; }

.quoter { border: 1px solid var(--line); border-radius: var(--radius); padding: 1rem 1.1rem; margin: 0 0 1.25rem; background: var(--ink-sunken); }
.quoter__row { display: grid; grid-template-columns: 1fr 1.4fr; gap: 1rem; }
.quoter__row .field { margin: 0; }
.quoter__out { display: grid; gap: .2rem; margin-top: 1rem; padding-top: .9rem; border-top: 1px solid var(--line); }
.quoter__label { font-size: .78rem; letter-spacing: .06em; text-transform: uppercase; color: var(--text-faint); }
.quoter__result { font-family: var(--mono); font-size: 1.35rem; font-weight: 600; color: var(--forge); word-break: break-all; }
@media (max-width: 620px) { .quoter__row { grid-template-columns: 1fr; } }

.attempts { list-style: none; margin: 1rem 0 0; padding: 0; display: grid; gap: .4rem; }
.attempt { display: flex; align-items: baseline; gap: .6rem; font-size: .88rem; padding: .45rem .6rem; border-radius: var(--radius); background: var(--ink-sunken); border: 1px solid var(--line); }
.attempt__badge { font-family: var(--mono); font-size: .7rem; letter-spacing: .06em; text-transform: uppercase; padding: .1rem .4rem; border-radius: 4px; flex: none; }
.attempt--ok .attempt__badge { color: #4ecdc4; border: 1px solid rgba(78,205,196,.35); }
.attempt--refused .attempt__badge { color: #ffc44d; border: 1px solid rgba(255,196,77,.35); }
.attempt__detail { color: var(--text-dim); word-break: break-word; }
`;


/** Hooks with a working demo panel, and how each one wants to be presented. */
const DEMOS = JSON.parse(readFileSync(join(HERE, "demos.json"), "utf8"));
const DEMO_PANELS = new Set(Object.keys(DEMOS));



/** The local stack for a custom-curve hook, which owns its reserves and issues its own shares. */
function localCurveScript(hook, recipe) {
  return `// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {BaseCustomAccounting} from "uniswap-hooks/base/BaseCustomAccounting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DemoToken} from "src/demo/DemoToken.sol";
import {DemoRouter} from "src/demo/DemoRouter.sol";
import {${hook.contract}} from "src/hooks/${hook.contract}.sol";

/**
 * @title DeployLocal
 * @notice Brings this curve up on a local chain with two faucet tokens and enough liquidity to quote against.
 *
 * @dev A custom-curve hook holds its own reserves and issues its own shares, so liquidity goes in through the hook
 * rather than through a router, and the hook binds to the first pool that initializes with it.
 *
 *   anvil &
 *   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \\
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
 *
 * Writes web/local.json, which the site's build merges. Anvil's first key is public by design; never use it for real.
 */
contract DeployLocal is Script {
    uint160 internal constant FLAGS = uint160(${recipe.flags});
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant Q96 = 1 << 96;

    PoolManager internal manager;
    DemoToken internal weth;
    DemoToken internal dai;
    DemoRouter internal router;
    ${hook.contract} internal hook;
    PoolKey internal key;

    function run() external {
        vm.startBroadcast();

        manager = new PoolManager(msg.sender);
        weth = new DemoToken("Hook Demo Ether", "hETH");
        dai = new DemoToken("Hook Demo Dollar", "hUSD");
        router = new DemoRouter(IPoolManager(address(manager)));

        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, FLAGS, type(${hook.contract}).creationCode, abi.encode(${recipe.constructorArgs})
        );
        hook = new ${hook.contract}{salt: salt}(${recipe.constructorArgs});
        require(address(hook) == predicted, "hook landed at an unexpected address");

        _openPool();
        vm.stopBroadcast();

        string memory config = string.concat(
            '{"chains":{"31337":{"rpcUrl":"http://127.0.0.1:8545","poolManager":"', vm.toString(address(manager)),
            '","router":"', vm.toString(address(router)),
            '","hook":"', vm.toString(address(hook)),
            '","currency0":"', vm.toString(Currency.unwrap(key.currency0)),
            '","currency1":"', vm.toString(Currency.unwrap(key.currency1)),
            '","poolId":"', vm.toString(PoolId.unwrap(key.toId())),
            '","fee":', vm.toString(uint256(key.fee)),
            ',"tickSpacing":', vm.toString(uint256(uint24(key.tickSpacing))),
            ',"zeroForOne":true,"faucet":true,"demoSwapAmount":"10000000000000000"}}}'
        );
        vm.writeFile("web/local.json", config);
        console2.log("Wrote web/local.json. Now: node web/build.mjs && npx serve web/dist");
        console2.log(config);
    }

    function _openPool() private {
        (Currency currency0, Currency currency1) = address(weth) < address(dai)
            ? (Currency.wrap(address(weth)), Currency.wrap(address(dai)))
            : (Currency.wrap(address(dai)), Currency.wrap(address(weth)));

        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(key, SQRT_PRICE_1_1);

        weth.claim();
        dai.claim();
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 50e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }
}
`;
}

/**
 * The local deploy script a spun-out repository ships, so anybody can bring the hook up and use its demo in one
 * command, with no funds and no wallet risk.
 *
 * Generated from the hook's own configure signature rather than written by hand per repository, because a script
 * that drifts from the contract it deploys is worse than no script.
 */
function localDeployScript(hook, recipe) {
  return `// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DemoToken} from "src/demo/DemoToken.sol";
import {DemoRouter} from "src/demo/DemoRouter.sol";
import {${hook.contract}} from "src/hooks/${hook.contract}.sol";

/**
 * @title DeployLocal
 * @notice Brings the whole demo up on a local chain: a PoolManager, two faucet tokens, a router a browser can drive,
 * this hook, a configured pool and enough liquidity to trade it.
 *
 * @dev A hook nobody can click is a blog post. This is what makes the site's "Try it" section work without anybody
 * spending anything on a public network:
 *
 *   anvil &
 *   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \\
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
 *
 * The last line is the JSON the site's web/src/deployments.json wants. Anvil's first account is pre-funded and its
 * key is public by design; never use it anywhere real.
 */
contract DeployLocal is Script {
    uint160 internal constant FLAGS = uint160(${recipe.flags});
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant Q96 = 1 << 96;

    PoolManager internal manager;
    DemoToken internal weth;
    DemoToken internal dai;
    DemoRouter internal router;
    ${hook.contract} internal hook;
    PoolKey internal key;

    function run() external {
        vm.startBroadcast();

        manager = new PoolManager(msg.sender);
        weth = new DemoToken("Hook Demo Ether", "hETH");
        dai = new DemoToken("Hook Demo Dollar", "hUSD");
        router = new DemoRouter(IPoolManager(address(manager)));

        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, FLAGS, type(${hook.contract}).creationCode, abi.encode(IPoolManager(address(manager)))
        );
        hook = new ${hook.contract}{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == predicted, "hook landed at an unexpected address");

        _openPool();
        vm.stopBroadcast();

        string memory config = string.concat(
                '{"chains":{"31337":{"rpcUrl":"http://127.0.0.1:8545","poolManager":"', vm.toString(address(manager)),
                '","router":"', vm.toString(address(router)),
                '","hook":"', vm.toString(address(hook)),
                '","currency0":"', vm.toString(Currency.unwrap(key.currency0)),
                '","currency1":"', vm.toString(Currency.unwrap(key.currency1)),
                '","poolId":"', vm.toString(PoolId.unwrap(key.toId())),
                '","fee":', vm.toString(uint256(key.fee)),
                ',"tickSpacing":', vm.toString(uint256(uint24(key.tickSpacing))),
                ',"zeroForOne":true,"faucet":true,"demoSwapAmount":"10000000000000000"}}}'
        );

        // Written rather than printed, so bringing the demo up is one command and not a copy-paste. The site's
        // build merges this over whatever is baked in, and .gitignore keeps it out of the repository: it names
        // addresses that exist only on the machine that ran this.
        vm.writeFile("web/local.json", config);

        console2.log("Wrote web/local.json. Now: node web/build.mjs && npx serve web/dist");
        console2.log(config);
    }

    function _openPool() private {
        (Currency currency0, Currency currency1) = address(weth) < address(dai)
            ? (Currency.wrap(address(weth)), Currency.wrap(address(dai)))
            : (Currency.wrap(address(dai)), Currency.wrap(address(weth)));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: ${recipe.dynamicFee ? "LPFeeLibrary.DYNAMIC_FEE_FLAG" : "3000"},
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        hook.configure(key, ${recipe.config});
        router.initialize(key, SQRT_PRICE_1_1);

        weth.claim();
        dai.claim();
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 5e18, salt: bytes32(0)}),
            ""
        );
    }
}
`;
}

/** Whether a hook ships a script that stands its demo up on a local chain. */
export function hasLocalDemo(slug) {
  return Boolean(DEMOS[slug]?.localDeploy);
}

/** Bundles the demo app once and returns the code, so every repository ships a build with no install step. */
function demoBundle() {
  const entry = join(HERE, "app", "main.js");
  const out = join(HERE, "app", ".bundle.js");
  execFileSync(
    "npx",
    ["esbuild", entry, "--bundle", "--format=esm", "--minify", "--target=es2022", `--outfile=${out}`],
    {cwd: join(HERE, "..", ".."), stdio: "pipe"},
  );
  return readFileSync(out, "utf8");
}

/**
 * The config the page's demo reads: where the hook is deployed, and how this hook wants to be shown.
 *
 * Returns null when the hook has no demo at all, so a page never ships an interactive section that cannot work.
 */
function deploymentsFor(slug, hookAbi) {
  const demo = DEMOS[slug];
  if (!demo) return null;

  const path = join(HERE, "deployments", `${slug}.json`);
  const deployments = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {chains: {}};

  // The hook's own error fragments travel with the config, so a refusal renders as the name the contract gave it
  // rather than as a selector. Uniswap v4 wraps hook reverts, so without these every refusal is unreadable.
  //
  // Held at the top level rather than per chain: a local deploy merges its chain in afterwards, and anything
  // attached to a chain that did not exist at generation time is simply lost.
  const errors = (hookAbi ?? []).filter((entry) => entry.type === "error");
  return JSON.stringify({...deployments, errors, demo});
}

/**
 * The demo section.
 *
 * Rendered server-side down to the explanation, so a visitor with no JavaScript still learns what the demo would do
 * and how to run it locally. The interactive part replaces the placeholder once the bundle loads.
 */
function demoSection(hook, deployments, repoUrl) {
  if (!DEMO_PANELS.has(hook.slug)) return "";

  return `
  <section class="shell">
    <h2 id="try">Try it</h2>
    <p>
      This is the hook running, not a picture of it. Connect a wallet on a chain it is deployed to, or bring the whole
      stack up locally in one command and use it with no funds and no wallet risk at all.
    </p>
    <div class="demo" data-demo="${esc(hook.slug)}">
      <div class="panel panel--empty">
        <p>Loading the demo\u2026 if this does not change, JavaScript is blocked and the demo cannot run.</p>
      </div>
    </div>
    <details class="raw">
      <summary>Run the whole thing locally</summary>
      <pre><code>git clone --recurse-submodules ${esc(repoUrl)}
cd ${esc(hook.slug)}

anvil &amp;
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \\
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

node web/build.mjs &amp;&amp; npx serve web/dist</code></pre>
      <p class="muted">
        The deploy script writes <code>web/local.json</code> itself and the build merges it, so the page points at the
        chain you just created without you editing anything. Point a wallet at
        <code>http://127.0.0.1:8545</code> and every button on this page works.
      </p>
      <p class="muted">
        Anvil's first account is pre-funded and its key is public by design. Never use it anywhere real.
      </p>
    </details>
  </section>
${deployments ? `  <script type="application/json" id="deployments">${deployments.replace(/</g, "\\u003c")}</script>` : ""}
  <script type="module" src="/assets/demo.js"></script>`;
}

const esc = (value) =>
  String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");

/** The build script that lands in the repository: no dependencies, reads `hook.json`, writes `dist/`. */
function buildScript(hook, siteUrl, repoUrl, catalogueUrl) {
  return `#!/usr/bin/env node
/**
 * Builds this hook's site.
 *
 * Everything on the page comes from \`hook.json\`, which is generated from the contract, so the page cannot describe
 * the hook as something it is not. No dependencies: run \`node web/build.mjs\` and publish \`web/dist\`.
 */
import {cpSync, existsSync, mkdirSync, readFileSync, writeFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DIST = join(HERE, "dist");
const hook = JSON.parse(readFileSync(join(HERE, "..", "hook.json"), "utf8"));

const SITE = ${JSON.stringify(siteUrl)};
const REPO = ${JSON.stringify(repoUrl)};
const CATALOGUE = ${JSON.stringify(catalogueUrl)};

let page = readFileSync(join(HERE, "src", "index.html"), "utf8");

// A local deploy writes web/local.json. Merge it over the baked-in config so the demo points at the chain the
// person running it actually has, without them editing anything. Spliced by index rather than by regular
// expression: the pattern would have to survive several layers of templating to get here intact, and this cannot
// be got subtly wrong.
const localPath = join(HERE, "local.json");
if (existsSync(localPath)) {
  const openTag = '<script type="application/json" id="deployments">';
  const closeTag = "</" + "script>";
  const from = page.indexOf(openTag);
  const to = from === -1 ? -1 : page.indexOf(closeTag, from);
  if (from !== -1 && to !== -1) {
    const baked = JSON.parse(page.slice(from + openTag.length, to).split("\\u003c").join("<"));
    const local = JSON.parse(readFileSync(localPath, "utf8"));
    const merged = {...baked, chains: {...baked.chains, ...local.chains}};
    const encoded = JSON.stringify(merged).split("<").join("\\u003c");
    page = page.slice(0, from + openTag.length) + encoded + page.slice(to);
    console.log("merged web/local.json into the page config");
  }
}

mkdirSync(join(DIST, "assets"), {recursive: true});
writeFileSync(join(DIST, "index.html"), page);
cpSync(join(HERE, "src", "site.css"), join(DIST, "assets", "site.css"));
cpSync(join(HERE, "src", "scene.js"), join(DIST, "assets", "scene.js"));
if (existsSync(join(HERE, "src", "demo.js"))) cpSync(join(HERE, "src", "demo.js"), join(DIST, "assets", "demo.js"));
cpSync(join(HERE, "src", "og.png"), join(DIST, "og.png"));
cpSync(join(HERE, "..", "hook.json"), join(DIST, "hook.json"));

writeFileSync(
  join(DIST, "robots.txt"),
  \`User-agent: *
Allow: /

Sitemap: \${SITE}/sitemap.xml
\`,
);

writeFileSync(
  join(DIST, "sitemap.xml"),
  \`<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>\${SITE}/</loc><lastmod>\${new Date().toISOString().slice(0, 10)}</lastmod><priority>1.0</priority></url>
</urlset>
\`,
);

writeFileSync(
  join(DIST, "llms.txt"),
  \`# \${hook.name}

> \${hook.summary}

A production Uniswap v4 hook. Source: \${REPO}. Part of the HookForge catalogue: \${CATALOGUE}

## How it works
\${hook.description}

## Prior art
\${hook.priorArt}

## Where it does not help
\${hook.limitation}

## Facts
Slug: \${hook.slug}
Contract: \${hook.contract}
Callbacks: \${Object.entries(hook.permissions ?? {}).filter(([, on]) => on).map(([n]) => n).join(", ") || "none"}
Parameters: \${(hook.configure?.fields ?? []).map((f) => f.name + " (" + f.type + ")").join(", ") || "none"}
Dynamic fee required: \${hook.properties?.dynamicFee ? "yes" : "no"}

## Caveats
- Unaudited.
- A deployment with status "deterministic" is a mined CREATE2 address with no code at it yet. Never present one as live.
\`,
);

writeFileSync(
  join(DIST, "_headers"),
  \`/assets/*
  Cache-Control: public, max-age=31536000, immutable

/hook.json
  Cache-Control: public, max-age=300
  Access-Control-Allow-Origin: *

/llms.txt
  Content-Type: text/plain; charset=utf-8
  Access-Control-Allow-Origin: *

/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
\`,
);

console.log("built " + hook.slug + " site into web/dist");
`;
}

function indexHtml(hook, {siteUrl, repoUrl, catalogueUrl, deployments}) {
  const claimed = claimedFlags(hook);
  const allFlags = [
    "beforeInitialize", "afterInitialize", "beforeAddLiquidity", "afterAddLiquidity",
    "beforeRemoveLiquidity", "afterRemoveLiquidity", "beforeSwap", "afterSwap",
    "beforeDonate", "afterDonate", "beforeSwapReturnsDelta", "afterSwapReturnsDelta",
    "afterAddLiquidityReturnsDelta", "afterRemoveLiquidityReturnsDelta",
  ];

  const md = (text) =>
    paragraphs(text)
      .split("\n\n")
      .filter(Boolean)
      .map((block) => `<p>${esc(block)}</p>`)
      .join("\n      ");

  const table = (markdown) => {
    const rows = markdown.trim().split("\n").filter((line) => line.startsWith("|"));
    if (rows.length < 2) return `<p>${esc(markdown)}</p>`;
    const cells = (line) => line.split("|").slice(1, -1).map((c) => c.trim());
    const head = cells(rows[0]);
    const body = rows.slice(2).map(cells);
    const render = (text) => esc(text).replace(/`([^`]+)`/g, "<code>$1</code>");
    return `<table>
        <thead><tr>${head.map((h) => `<th>${render(h)}</th>`).join("")}</tr></thead>
        <tbody>${body.map((row) => `<tr>${row.map((c) => `<td>${render(c)}</td>`).join("")}</tr>`).join("\n          ")}</tbody>
      </table>`;
  };

  const configureSnippet = hook.configure
    ? `hook.configure(
    key,
    ${hook.contract}.Config({
${(hook.configure.fields ?? []).map((f) => `        ${f.name}: /* ${f.type} */ 0`).join(",\n") || "        // no parameters"}
    })
);

poolManager.initialize(key, startingSqrtPriceX96);`
    : `poolManager.initialize(key, startingSqrtPriceX96);`;

  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareSourceCode",
    name: hook.name,
    description: hook.summary,
    url: siteUrl,
    codeRepository: repoUrl,
    programmingLanguage: "Solidity",
    runtimePlatform: "Ethereum Virtual Machine",
    license: "https://www.apache.org/licenses/LICENSE-2.0",
    keywords: hook.tags.join(", "),
    isPartOf: {"@type": "WebSite", name: "HookForge", url: catalogueUrl},
  };

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(hook.name)}: ${esc(hook.summary.replace(/\.$/, ""))}</title>
<meta name="description" content="${esc(hook.summary.slice(0, 300))}">
<link rel="canonical" href="${esc(siteUrl)}/">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="theme-color" content="#07080b">

<meta property="og:type" content="website">
<meta property="og:site_name" content="${esc(hook.name)}">
<meta property="og:title" content="${esc(hook.name)}">
<meta property="og:description" content="${esc(hook.summary.slice(0, 300))}">
<meta property="og:url" content="${esc(siteUrl)}/">
<meta property="og:image" content="${esc(siteUrl)}/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(hook.name)}">
<meta name="twitter:description" content="${esc(hook.summary.slice(0, 300))}">
<meta name="twitter:image" content="${esc(siteUrl)}/og.png">

<link rel="stylesheet" href="/assets/site.css">
<link rel="alternate" type="text/plain" title="For language models" href="/llms.txt">
<script type="importmap">{"imports":{"three":"${THREE_CDN}"}}</script>
<script type="application/ld+json">${JSON.stringify(jsonLd)}</script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="masthead">
  <div class="shell masthead__inner">
    <a class="brand" href="/">${esc(hook.name)}</a>
    <nav aria-label="Primary">
      <a href="#how">How it works</a>
      <a href="#using">Using it</a>
      <a href="#deploy">Deploy</a>
      <a href="${esc(repoUrl)}" rel="noopener">GitHub</a>
      <a href="${esc(catalogueUrl)}" rel="noopener">Catalogue</a>
    </nav>
  </div>
</header>

<main id="main">
  <div class="stage">
    <div class="scene">
      <canvas data-permissions="${esc(JSON.stringify(hook.permissions ?? {}))}" aria-hidden="true"></canvas>
      <p class="scene__fallback">${esc(hook.name)} implements ${claimed.length} of the fourteen Uniswap v4 callbacks: ${
    claimed.join(", ") || "none"
  }.</p>
    </div>
    <p class="scene__hint">drag to orbit</p>

  <section class="shell hero">
    <p class="eyebrow">Uniswap v4 hook &middot; ${esc(hook.family)}</p>
    <h1>${esc(hook.name)}</h1>
    <p class="lede">${esc(hook.summary)}</p>
    <div class="cta-row">
      <a class="btn btn--primary" href="${esc(repoUrl)}" rel="noopener">Source on GitHub</a>
      <a class="btn" href="#using">Use it in a pool</a>
      <a class="btn" href="/hook.json">Manifest JSON</a>
    </div>

    <dl class="stats">
      <div class="stat"><dt>Family</dt><dd>${esc(hook.family)}</dd></div>
      <div class="stat"><dt>Callbacks</dt><dd>${claimed.length} of 14</dd></div>
      <div class="stat"><dt>Fee</dt><dd>${hook.properties?.dynamicFee ? "dynamic" : "static"}</dd></div>
      <div class="stat"><dt>Admin keys</dt><dd>none</dd></div>
      <div class="stat"><dt>Licence</dt><dd>Apache-2.0</dd></div>
    </dl>
  </section>
  </div>

  <section class="shell">
    <h2 id="how">How it works</h2>
      ${md(hook.description)}

    ${hook.priorArt ? `<div class="callout callout--prior"><h3>Prior art</h3>${md(hook.priorArt)}</div>` : ""}
    ${hook.limitation ? `<div class="callout callout--warn"><h3>Where it does not help</h3>${md(hook.limitation)}</div>` : ""}

    <h2 id="using">Using it</h2>
    <p>
      Uniswap v4 removed <code>hookData</code> from <code>initialize</code>, so per-pool parameters arrive out of band.
      Fix them for a pool key whose pool does not exist yet, then initialize. Nobody can change them afterwards,
      including you.
    </p>
    <pre><code>${esc(configureSnippet)}</code></pre>
    ${
      hook.properties?.dynamicFee
        ? `<p>The pool's <code>fee</code> field must be <code>LPFeeLibrary.DYNAMIC_FEE_FLAG</code>. The hook rejects a pool initialized without it, which is the most common integration failure.</p>`
        : ""
    }

    <h3>Parameters</h3>
    ${table(parameterTable(hook))}

    <h3>From TypeScript</h3>
    <pre><code>npm i @hookforge/sdk

import {getHook, hookAddress, poolKeyFor} from "@hookforge/sdk";

const hook = getHook("${esc(hook.slug)}");
const key  = poolKeyFor({
  hook: hookAddress("${esc(hook.slug)}", 8453),   // Base
  currencyA: USDC, currencyB: WETH,
  tickSpacing: 60${hook.properties?.dynamicFee ? ", dynamicFee: true" : ""},
});</code></pre>

    ${errorTable(hook) ? `<h2>What it reverts with</h2>\n    ${table(errorTable(hook).split("\n").filter((l) => l.startsWith("|")).join("\n"))}` : ""}

    <h2>The callbacks it claims</h2>
    <p>
      Uniswap v4 reads a hook's permissions from the low fourteen bits of its own address, which is why deploying one
      means mining a CREATE2 salt. This hook claims ${claimed.length}, so every deployment of it has an address ending
      in <code>0x${flagMask(hook).toString(16)}</code>.
    </p>
    <ul class="flags">${allFlags
      .map((flag) => `<li class="flag${hook.permissions?.[flag] ? " flag--on" : ""}">${esc(flag)}</li>`)
      .join("")}</ul>

    <h2>It says what it is, on-chain</h2>
    <p>
      Nothing about a hook's address tells an indexer, a wallet, a router or an agent what the pool does, which is why
      hook discovery today is a curated list. This hook answers for itself, in one <code>eth_call</code>, with no
      registry in the loop.
    </p>
    <pre><code>cast call $HOOK "hookName()(string)"    # ${esc(hook.name)}
cast call $HOOK "specURI()(string)"     # ${esc(siteUrl)}/hook.json
cast call $HOOK "hookTags()(string[])"  # ${esc(hook.tags.join(", "))}</code></pre>

    <h2 id="deploy">Build, test and deploy</h2>
    <pre><code>git clone --recurse-submodules ${esc(repoUrl)}
cd ${esc(hook.slug)}
forge build &amp;&amp; forge test

# Dry run: mines the salt, prints the address, sends nothing.
forge script script/Deploy.s.sol --rpc-url $RPC_URL

# For real.
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify</code></pre>

    <div class="callout callout--warn">
      <h3>Status</h3>
      <p>
        <strong>Unaudited.</strong> Built to an audited shape, on OpenZeppelin's audited hook bases, and tested against
        a real <code>PoolManager</code>. No third party has reviewed it. Read "where it does not help" above before
        putting money behind it. Not affiliated with Uniswap Labs.
      </p>
    </div>
  </section>
${demoSection(hook, deployments, repoUrl)}
</main>

<footer class="foot">
  <div class="shell">
    <p>
      <a href="${esc(repoUrl)}" rel="noopener">Source</a> &middot;
      <a href="/hook.json">Manifest</a> &middot;
      <a href="/llms.txt">llms.txt</a> &middot;
      <a href="${esc(catalogueUrl)}" rel="noopener">The rest of the catalogue</a>
    </p>
    <p>Apache-2.0 licensed. Not affiliated with Uniswap Labs.</p>
  </div>
</footer>
<script type="module" src="/assets/scene.js"></script>
</body>
</html>
`;
}

/** Writes the whole `web/` tree, including the rasterised social card. */
export function emitSite(repo, hook, {siteUrl, repoUrl, catalogueUrl}) {
  const deployments = deploymentsFor(hook.slug, hook.abi);

  write(repo, "web/build.mjs", buildScript(hook, siteUrl, repoUrl, catalogueUrl));
  write(repo, "web/src/index.html", indexHtml(hook, {siteUrl, repoUrl, catalogueUrl, deployments}));
  if (DEMO_PANELS.has(hook.slug)) write(repo, "web/src/demo.js", demoBundle());

  // A hook with a local-deploy recipe ships the script and the demo contracts it needs, so its "Try it" section
  // works for anybody with Foundry and no funds at all.
  const recipe = DEMOS[hook.slug]?.localDeploy;
  if (recipe) {
    write(repo, "script/DeployLocal.s.sol", recipe.curve ? localCurveScript(hook, recipe) : localDeployScript(hook, recipe));
  }
  write(repo, "web/src/site.css", CSS);
  write(repo, "web/src/scene.js", SCENE);
  writeFileSync(join(repo, "web", "src", "og.png"), hookCard(hook));
}
