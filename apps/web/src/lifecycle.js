import {
  AdditiveBlending,
  CanvasTexture,
  Color,
  Group,
  Mesh,
  MeshBasicMaterial,
  OrthographicCamera,
  PlaneGeometry,
  Scene,
  SphereGeometry,
  Sprite,
  SpriteMaterial,
  TorusGeometry,
  WebGLRenderer,
} from "three";

/**
 * The per-hook scene: the Uniswap v4 callback pipeline, with this hook's callbacks lit.
 *
 * A swap runs left to right through the gates the protocol offers. The ones this hook implements glow and pulse as
 * the swap passes; the ones it does not are dark and inert. That is the whole contract between a hook and the
 * protocol, and reading it off a picture is faster than reading it off fourteen booleans.
 */

/** The callbacks worth drawing, in the order a swap actually encounters them. */
const STAGES = [
  {key: "beforeInitialize", label: "beforeInitialize"},
  {key: "afterInitialize", label: "afterInitialize"},
  {key: "beforeAddLiquidity", label: "beforeAddLiquidity"},
  {key: "afterAddLiquidity", label: "afterAddLiquidity"},
  {key: "beforeSwap", label: "beforeSwap"},
  {key: "afterSwap", label: "afterSwap"},
  {key: "beforeRemoveLiquidity", label: "beforeRemoveLiq"},
  {key: "afterRemoveLiquidity", label: "afterRemoveLiq"},
  {key: "beforeDonate", label: "beforeDonate"},
  {key: "afterDonate", label: "afterDonate"},
];

const ON = new Color("#ff6a2b");
const OFF = new Color("#232a35");

/** Draws a label into a canvas texture, so the scene carries its own type and never waits on a webfont. */
function labelSprite(text, active) {
  const canvas = document.createElement("canvas");
  const scale = 3;
  canvas.width = 300 * scale;
  canvas.height = 56 * scale;

  const ctx = canvas.getContext("2d");
  ctx.scale(scale, scale);
  ctx.font = "500 19px ui-monospace, SFMono-Regular, Menlo, monospace";
  ctx.fillStyle = active ? "#e8eaef" : "#5a6373";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, 150, 28);

  const sprite = new Sprite(new SpriteMaterial({map: new CanvasTexture(canvas), transparent: true, depthTest: false}));
  sprite.scale.set(2.6, 0.49, 1);
  return sprite;
}

export function mountLifecycle(canvas, permissions) {
  if (!canvas || !permissions) return () => {};

  let renderer;
  try {
    renderer = new WebGLRenderer({canvas, antialias: true, alpha: true, powerPreference: "low-power"});
  } catch {
    return () => {};
  }

  const fallback = canvas.parentElement?.querySelector(".lifecycle__fallback");
  if (fallback) fallback.remove();

  const scene = new Scene();
  const camera = new OrthographicCamera(-1, 1, 1, -1, 0.1, 100);
  camera.position.z = 10;

  const root = new Group();
  scene.add(root);

  const spacing = 1.6;
  const span = (STAGES.length - 1) * spacing;
  const gates = [];

  // The rail the swap travels along.
  const rail = new Mesh(
    new PlaneGeometry(span + spacing, 0.012),
    new MeshBasicMaterial({color: OFF, transparent: true, opacity: 0.7}),
  );
  root.add(rail);

  STAGES.forEach((stage, index) => {
    const active = Boolean(permissions[stage.key]);
    const x = index * spacing - span / 2;

    const ring = new Mesh(
      new TorusGeometry(0.34, active ? 0.035 : 0.018, 10, 56),
      new MeshBasicMaterial({color: active ? ON : OFF, transparent: true, opacity: active ? 0.95 : 0.55}),
    );
    ring.position.set(x, 0, 0);
    root.add(ring);

    let glow = null;
    if (active) {
      glow = new Mesh(
        new TorusGeometry(0.34, 0.13, 10, 56),
        new MeshBasicMaterial({color: ON, transparent: true, opacity: 0.1, blending: AdditiveBlending}),
      );
      glow.position.copy(ring.position);
      root.add(glow);
    }

    const label = labelSprite(stage.label, active);
    label.position.set(x, -0.78, 0);
    root.add(label);

    gates.push({x, active, ring, glow});
  });

  const swap = new Mesh(
    new SphereGeometry(0.085, 16, 16),
    new MeshBasicMaterial({color: new Color("#4ecdc4")}),
  );
  root.add(swap);

  function resize() {
    const {clientWidth, clientHeight} = canvas;
    if (clientWidth === 0 || clientHeight === 0) return;

    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(clientWidth, clientHeight, false);

    // Frame the whole pipeline with a margin, whatever the container's aspect ratio.
    const worldWidth = span + spacing * 1.4;
    const halfHeight = (worldWidth * clientHeight) / clientWidth / 2;
    camera.left = -worldWidth / 2;
    camera.right = worldWidth / 2;
    camera.top = halfHeight;
    camera.bottom = -halfHeight;
    camera.updateProjectionMatrix();
  }

  const startX = -span / 2 - spacing * 0.7;
  const endX = span / 2 + spacing * 0.7;

  function step(elapsed) {
    const cycle = (elapsed % 7) / 7;
    const x = startX + (endX - startX) * cycle;
    swap.position.set(x, 0, 0.2);

    for (const gate of gates) {
      if (!gate.active) continue;
      const distance = Math.abs(x - gate.x);
      const excitement = Math.max(0, 1 - distance / 0.75);
      gate.ring.material.opacity = 0.72 + excitement * 0.28;
      gate.ring.scale.setScalar(1 + excitement * 0.16);
      if (gate.glow) gate.glow.material.opacity = 0.07 + excitement * 0.3;
    }
  }

  const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;

  let raf = 0;
  let elapsed = 0;
  let last = performance.now();
  let visible = true;

  function frame(now) {
    raf = requestAnimationFrame(frame);
    const delta = Math.min((now - last) / 1000, 0.05);
    last = now;
    if (!visible) return;

    elapsed += delta;
    step(elapsed);
    renderer.render(scene, camera);
  }

  resize();
  if (reduced) {
    // Park the swap on the first callback the hook implements, so the still frame still says something.
    const firstActive = gates.find((gate) => gate.active);
    step(firstActive ? ((firstActive.x - startX) / (endX - startX)) * 7 : 0);
    renderer.render(scene, camera);
  } else {
    raf = requestAnimationFrame(frame);
  }

  const onResize = () => resize();
  window.addEventListener("resize", onResize, {passive: true});

  const observer = new IntersectionObserver((entries) => {
    visible = entries.some((entry) => entry.isIntersecting);
  });
  observer.observe(canvas);

  return () => {
    cancelAnimationFrame(raf);
    window.removeEventListener("resize", onResize);
    observer.disconnect();
    renderer.dispose();
  };
}
