import {
  AdditiveBlending,
  BufferAttribute,
  BufferGeometry,
  CatmullRomCurve3,
  Color,
  Group,
  Mesh,
  MeshBasicMaterial,
  PerspectiveCamera,
  Points,
  PointsMaterial,
  Scene,
  TorusGeometry,
  TubeGeometry,
  Vector3,
  WebGLRenderer,
} from "three";

/**
 * The hero scene: a constant-product curve with order flow running along it, passing through a hook.
 *
 * It is a picture of the one idea the whole catalogue rests on. The ribbon is `x * y = k`, the curve every Uniswap
 * pool has always traded on. The ring at its centre is the hook. Flow enters cool and leaves warm, because a hook
 * gets to price a swap on its way through, and that is the entire surface these fifty contracts are built on.
 */

const FLOW_COUNT = 900;
const CURVE_SAMPLES = 160;

/** Samples the constant-product hyperbola into a 3D curve, with a gentle twist so it reads as a ribbon in motion. */
function productCurve() {
  const points = [];
  for (let i = 0; i < CURVE_SAMPLES; i++) {
    const t = i / (CURVE_SAMPLES - 1);
    // x runs from 0.22 to 4.6 and y = 1 / x, recentred so the middle of the curve sits at the origin.
    const x = 0.22 + t * 4.38;
    points.push(new Vector3(x - 2.4, 1 / x - 1.1, Math.sin(t * Math.PI * 2) * 0.22));
  }
  return new CatmullRomCurve3(points);
}

export function mountHero(canvas) {
  if (!canvas) return () => {};

  let renderer;
  try {
    renderer = new WebGLRenderer({canvas, antialias: true, alpha: true, powerPreference: "low-power"});
  } catch {
    // No WebGL. The page is fully readable without the scene, so there is nothing to fall back to.
    return () => {};
  }

  const scene = new Scene();
  const camera = new PerspectiveCamera(42, 1, 0.1, 100);
  camera.position.set(0.1, 0.35, 6.2);

  const root = new Group();
  scene.add(root);

  const curve = productCurve();

  const ribbon = new Mesh(
    new TubeGeometry(curve, 220, 0.016, 10, false),
    new MeshBasicMaterial({color: new Color("#2a303c")}),
  );
  root.add(ribbon);

  // The hook: a ring the flow has to pass through, at the middle of the curve.
  const gate = new Mesh(
    new TorusGeometry(0.42, 0.014, 12, 96),
    new MeshBasicMaterial({color: new Color("#ff6a2b"), transparent: true, opacity: 0.9}),
  );
  gate.position.copy(curve.getPointAt(0.5));
  gate.lookAt(curve.getPointAt(0.53));
  root.add(gate);

  const halo = new Mesh(
    new TorusGeometry(0.42, 0.05, 12, 96),
    new MeshBasicMaterial({color: new Color("#ff6a2b"), transparent: true, opacity: 0.12, blending: AdditiveBlending}),
  );
  halo.position.copy(gate.position);
  halo.rotation.copy(gate.rotation);
  root.add(halo);

  // Order flow. Each particle carries its own position along the curve and its own speed.
  const offsets = new Float32Array(FLOW_COUNT);
  const speeds = new Float32Array(FLOW_COUNT);
  const positions = new Float32Array(FLOW_COUNT * 3);
  const colors = new Float32Array(FLOW_COUNT * 3);

  for (let i = 0; i < FLOW_COUNT; i++) {
    offsets[i] = Math.random();
    speeds[i] = 0.012 + Math.random() * 0.03;
  }

  const flowGeometry = new BufferGeometry();
  flowGeometry.setAttribute("position", new BufferAttribute(positions, 3));
  flowGeometry.setAttribute("color", new BufferAttribute(colors, 3));

  const flow = new Points(
    flowGeometry,
    new PointsMaterial({size: 0.028, vertexColors: true, transparent: true, opacity: 0.95, blending: AdditiveBlending}),
  );
  root.add(flow);

  const cool = new Color("#4ecdc4");
  const warm = new Color("#ff6a2b");
  const scratch = new Color();
  const point = new Vector3();

  function resize() {
    const {clientWidth, clientHeight} = canvas;
    if (clientWidth === 0 || clientHeight === 0) return;

    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(clientWidth, clientHeight, false);
    camera.aspect = clientWidth / clientHeight;
    camera.updateProjectionMatrix();
  }

  function step(delta, elapsed) {
    for (let i = 0; i < FLOW_COUNT; i++) {
      offsets[i] = (offsets[i] + speeds[i] * delta) % 1;
      const t = offsets[i];
      curve.getPointAt(t, point);

      const spread = 0.035;
      positions[i * 3] = point.x + Math.sin(i * 12.9898 + elapsed * 0.4) * spread;
      positions[i * 3 + 1] = point.y + Math.cos(i * 78.233 + elapsed * 0.4) * spread;
      positions[i * 3 + 2] = point.z + Math.sin(i * 43.7 + elapsed * 0.3) * spread;

      // Flow warms as it crosses the hook: cool before the midpoint, forge orange after.
      scratch.copy(cool).lerp(warm, Math.min(1, Math.max(0, (t - 0.42) / 0.2)));
      colors[i * 3] = scratch.r;
      colors[i * 3 + 1] = scratch.g;
      colors[i * 3 + 2] = scratch.b;
    }

    flowGeometry.attributes.position.needsUpdate = true;
    flowGeometry.attributes.color.needsUpdate = true;

    halo.material.opacity = 0.1 + Math.sin(elapsed * 1.6) * 0.05;
    root.rotation.y = Math.sin(elapsed * 0.12) * 0.16;
    root.rotation.x = Math.sin(elapsed * 0.09) * 0.05;
  }

  const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;

  let raf = 0;
  let last = performance.now();
  let elapsed = 0;
  let visible = true;

  function frame(now) {
    raf = requestAnimationFrame(frame);
    const delta = Math.min((now - last) / 1000, 0.05);
    last = now;
    if (!visible) return;

    elapsed += delta;
    step(delta, elapsed);
    renderer.render(scene, camera);
  }

  resize();
  if (reduced) {
    // Draw one frame so the picture is there, and never animate it.
    step(0, 0);
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
    flowGeometry.dispose();
    ribbon.geometry.dispose();
    gate.geometry.dispose();
    halo.geometry.dispose();
    renderer.dispose();
  };
}
