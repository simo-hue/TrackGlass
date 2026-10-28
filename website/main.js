/* ==========================================================================
   Trackglass — site script (vanilla, no dependencies)
   ========================================================================== */
(() => {
  "use strict";

  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const easeInOut = t => (t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const easeOut = t => 1 - Math.pow(1 - t, 3);
  const easeIn = t => t * t * t;

  /* ------------------------------------------------------------------
     Stages: fixed design coordinates scaled to their container
     ------------------------------------------------------------------ */
  $$(".stage-wrap[data-stage]").forEach(wrap => {
    const [w, h] = wrap.dataset.stage.split("x").map(Number);
    const crop = wrap.dataset.crop ? wrap.dataset.crop.split(",").map(Number) : null;   // "x,width": narrow screens show this horizontal slice
    const narrow = matchMedia("(max-width: 640px)");
    wrap.style.setProperty("--w", w);
    wrap.style.setProperty("--h", h);
    const fit = () => {
      const useCrop = crop && narrow.matches;
      const visW = useCrop ? crop[1] : w;
      const s = wrap.clientWidth / visW;
      wrap.style.setProperty("--w", visW);
      wrap.style.setProperty("--s", s.toFixed(4));
      wrap.style.setProperty("--ox", useCrop ? (-crop[0] * s).toFixed(1) + "px" : "0px");
    };
    new ResizeObserver(fit).observe(wrap);
    narrow.addEventListener("change", fit);
    fit();
  });

  /* ------------------------------------------------------------------
     Nav
     ------------------------------------------------------------------ */
  const nav = $("#nav");
  const progress = $("#navProgress");
  const onScrollNav = () => {
    nav.classList.toggle("is-solid", scrollY > 24);
    if (progress) {
      const max = document.documentElement.scrollHeight - innerHeight;
      progress.style.setProperty("--p", max > 0 ? clamp(scrollY / max, 0, 1).toFixed(4) : 0);
    }
  };
  addEventListener("scroll", onScrollNav, { passive: true });
  onScrollNav();

  // Active section → sliding indicator behind the nav links
  (function navIndicator() {
    const links = $$(".nav__links a[data-nav]"), ind = $("#navInd"); if (!links.length || !ind) return;
    const place = a => {
      if (!a) { ind.style.setProperty("--o", 0); return; }
      ind.style.setProperty("--x", a.offsetLeft + "px"); ind.style.setProperty("--w", a.offsetWidth + "px"); ind.style.setProperty("--o", 1);
    };
    const visible = new Map();
    const io = new IntersectionObserver(entries => {
      entries.forEach(e => visible.set(e.target.id, e.isIntersecting));
      const active = links.map(a => a.dataset.nav).find(id => visible.get(id));
      links.forEach(a => a.classList.toggle("is-active", a.dataset.nav === active));
      place(links.find(a => a.dataset.nav === active));
    }, { rootMargin: "-40% 0px -50% 0px" });
    links.forEach(a => { const s = $("#" + a.dataset.nav); if (s) io.observe(s); });
    links.forEach(a => a.addEventListener("pointerenter", () => place(a)));
    $(".nav__links").addEventListener("pointerleave", () => place(links.find(a => a.classList.contains("is-active"))));
    addEventListener("resize", () => place(links.find(a => a.classList.contains("is-active"))));
  })();

  /* ------------------------------------------------------------------
     Mobile menu
     ------------------------------------------------------------------ */
  (function menu() {
    const btn = $("#navBurger"), sheet = $("#navSheet"); if (!btn || !sheet) return;
    const set = open => { nav.classList.toggle("is-open", open); btn.setAttribute("aria-expanded", String(open)); };
    btn.addEventListener("click", () => set(!nav.classList.contains("is-open")));
    sheet.addEventListener("click", e => { if (e.target.closest("a")) set(false); });
    addEventListener("keydown", e => { if (e.key === "Escape") set(false); });
    addEventListener("click", e => { if (!nav.contains(e.target)) set(false); });
  })();

  /* ------------------------------------------------------------------
     Cursor spotlight on glass panels
     ------------------------------------------------------------------ */
  if (!matchMedia("(hover: none)").matches) {
    $$("[data-spot]").forEach(el => {
      el.addEventListener("pointermove", e => {
        const r = el.getBoundingClientRect();
        el.style.setProperty("--mx", (e.clientX - r.left) + "px");
        el.style.setProperty("--my", (e.clientY - r.top) + "px");
      }, { passive: true });
    });
  }

  /* ------------------------------------------------------------------
     Ticker: duplicate once for a seamless loop
     ------------------------------------------------------------------ */
  (function ticker() {
    const t = $("#ticker"); if (!t) return;
    t.innerHTML += t.innerHTML;
  })();

  /* ------------------------------------------------------------------
     Theme stage: gentle 3D tilt toward the cursor
     ------------------------------------------------------------------ */
  (function tilt() {
    const stage = $("#themeStage"), pad = $("#themeIpad");
    if (!stage || !pad || reduced || matchMedia("(hover: none)").matches) return;
    stage.addEventListener("pointermove", e => {
      const r = stage.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width - .5, y = (e.clientY - r.top) / r.height - .5;
      pad.style.setProperty("--ry", (x * 10).toFixed(2) + "deg");
      pad.style.setProperty("--rx", (-y * 8).toFixed(2) + "deg");
    }, { passive: true });
    stage.addEventListener("pointerleave", () => { pad.style.setProperty("--ry", "0deg"); pad.style.setProperty("--rx", "0deg"); });
  })();

  /* ------------------------------------------------------------------
     Reveal on scroll
     ------------------------------------------------------------------ */
  const revealIO = new IntersectionObserver(entries => {
    entries.forEach(e => { if (e.isIntersecting) { e.target.classList.add("in"); revealIO.unobserve(e.target); } });
  }, { threshold: .12, rootMargin: "0px 0px -6% 0px" });
  $$(".reveal").forEach(el => revealIO.observe(el));

  /* ------------------------------------------------------------------
     Timeline helpers
     ------------------------------------------------------------------ */
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  function tween(ms, fn, ease = easeInOut, shouldAbort = () => false) {
    return new Promise(resolve => {
      const t0 = performance.now();
      const step = now => {
        if (shouldAbort()) return resolve(false);
        const t = clamp((now - t0) / ms, 0, 1);
        fn(ease(t), t);
        if (t < 1) requestAnimationFrame(step); else resolve(true);
      };
      requestAnimationFrame(step);
    });
  }

  /* ------------------------------------------------------------------
     Hero: live trackpad demo
     ------------------------------------------------------------------ */
  (function hero() {
    const glass = $("#heroGlass"); if (!glass) return;
    const halos = [0, 1, 2, 3].map(i => $("#halo" + i));
    const ripple = $("#ripple");
    const pointer = $("#pointer");
    const desk = $("#desk");
    const photoScroll = $("#pageScroll");
    const grid = $("#page");
    const btn = $("#demoBtn");
    const hint = $("#heroHint");
    const label = $("#captionLabel");
    const stepsEl = $("#captionSteps");

    // Contribution graph (illustrative pattern, deterministic)
    const contrib = $("#contrib");
    if (contrib) {
      let s = 1337; const rnd = () => { s = (s * 1103515245 + 12345) >>> 0; return (s >>> 8) / 16777216; };
      let html = "";
      for (let c = 0; c < 52; c++) for (let r = 0; r < 7; r++) {
        const season = .35 + .5 * Math.sin((c / 52) * Math.PI * 2 + 1.2);
        const v = rnd() * season; const l = v < .18 ? 0 : v < .34 ? 1 : v < .5 ? 2 : v < .66 ? 3 : 4;
        html += `<i data-l="${l}"></i>`;
      }
      contrib.innerHTML = html;
    }

    // Geometry (design px)
    const G = { w: 352, h: 242 };      // glass (iPad 380x270 minus 14px bezel)
    const D = { w: 696, h: 426 };      // desk
    const toDesk = (x, y) => ({ x: clamp(x / G.w * D.w, 0, D.w - 4), y: clamp(y / G.h * D.h, 0, D.h - 4) });
    const fromDesk = (x, y) => ({ x: x / D.w * G.w, y: y / D.h * G.h });

    const steps = ["Point", "Click", "Scroll", "Zoom", "Spaces"];
    stepsEl.innerHTML = steps.map(() => "<i></i>").join("");
    const stepDots = $$("i", stepsEl);
    const setStep = i => { label.textContent = steps[i]; stepDots.forEach((d, k) => d.classList.toggle("is-on", k <= i)); };

    const halo = (i, x, y, on = true, sc = 1) => {
      const h = halos[i]; h.style.setProperty("--x", x + "px"); h.style.setProperty("--y", y + "px"); h.style.setProperty("--sc", sc);
      h.classList.toggle("is-on", on);
    };
    const hideHalos = () => halos.forEach(h => h.classList.remove("is-on"));
    let px = 300, py = 200;                   // current pointer position on the desk (design px)
    const setPointer = (x, y) => { px = x; py = y; pointer.style.setProperty("--px", x + "px"); pointer.style.setProperty("--py", y + "px"); };
    const fingerToPointer = (x, y) => { const p = toDesk(x, y); setPointer(p.x, p.y); };
    // Like a real trackpad: the pointer follows the *motion* of the finger, not its absolute position.
    const movePointerBy = (dx, dy) => setPointer(clamp(px + dx, 0, D.w - 4), clamp(py + dy, 0, D.h - 4));
    const click = (x, y) => {
      ripple.style.setProperty("--x", x + "px"); ripple.style.setProperty("--y", y + "px");
      ripple.classList.remove("go"); void ripple.offsetWidth; ripple.classList.add("go");
      pointer.classList.add("is-down"); btn.classList.add("is-pressed");
      setTimeout(() => { pointer.classList.remove("is-down"); btn.classList.remove("is-pressed"); }, 160);
    };

    // State
    let userActiveUntil = 0;
    let visible = true;
    const userActive = () => performance.now() < userActiveUntil;
    const abort = () => userActive() || !visible;

    // User interaction: hover / touch on the glass drives the pointer live
    glass.style.touchAction = "pan-y";   // horizontal drags drive the pointer; vertical ones still scroll the page
    // The glass is drawn in perspective, so absolute positions on it map to the screen non-linearly.
    // The user's own cursor therefore drives the pointer by its screen-space *delta* (scaled back to design
    // pixels by the stage scale) with a fixed gain, exactly like a trackpad; the halo still sits under the
    // cursor at the element's own (untransformed) coordinates.
    const stageWrap = glass.closest(".stage-wrap");
    const GAIN = 1.7;                          // desk px per glass px of finger travel
    let last = null;
    const onMove = e => {
      const x = clamp(e.offsetX, 0, G.w), y = clamp(e.offsetY, 0, G.h);
      userActiveUntil = performance.now() + 2200;
      hideHalos(); halo(0, x, y, true, 1);
      if (last) {
        const s = parseFloat(stageWrap?.style.getPropertyValue("--s")) || 1;
        movePointerBy((e.clientX - last.x) / s * GAIN, (e.clientY - last.y) / s * GAIN);
      }
      last = { x: e.clientX, y: e.clientY };
      hint.classList.add("is-hidden");
      setStep(0);
    };
    glass.addEventListener("pointerenter", e => { last = { x: e.clientX, y: e.clientY }; });
    glass.addEventListener("pointermove", onMove);
    glass.addEventListener("pointerdown", e => { last = { x: e.clientX, y: e.clientY }; onMove(e); click(e.offsetX, e.offsetY); setStep(1); userActiveUntil = performance.now() + 2200; });
    glass.addEventListener("pointerup", () => { last = null; });
    glass.addEventListener("pointercancel", () => { last = null; });
    glass.addEventListener("pointerleave", () => { last = null; userActiveUntil = performance.now() + 900; });

    new IntersectionObserver(([e]) => { visible = e.isIntersecting; }, { threshold: .05 }).observe(glass);

    // Scripted loop
    const bez = (p0, p1, p2, t) => ({ x: (1 - t) * (1 - t) * p0.x + 2 * (1 - t) * t * p1.x + t * t * p2.x, y: (1 - t) * (1 - t) * p0.y + 2 * (1 - t) * t * p1.y + t * t * p2.y });

    async function waitIdle() {
      while (abort()) { await sleep(120); }
      // settle: fade whatever the user left
    }

    async function moveFinger(from, to, ms, via) {
      const ok = await tween(ms, t => {
        const p = via ? bez(from, via, to, t) : { x: lerp(from.x, to.x, t), y: lerp(from.y, to.y, t) };
        halo(0, p.x, p.y, true); fingerToPointer(p.x, p.y);
      }, easeInOut, abort);
      return ok;
    }

    async function run() {
      const BTN = fromDesk(136, 259);            // "Follow" button on the GitHub profile, mapped from desk to glass coordinates
      const PHOTOS = fromDesk(430, 260);
      // reset
      desk.classList.remove("is-space-b");
      photoScroll.style.setProperty("--scroll", "0px"); grid.style.setProperty("--zoom", 1);
      hideHalos();

      // 1. Point
      setStep(0);
      halo(0, 90, 110, true); fingerToPointer(90, 110);
      await sleep(350); if (abort()) return;
      if (!await moveFinger({ x: 90, y: 110 }, BTN, 1500, { x: 190, y: 50 })) return;
      await tween(220, t => { btn.classList.toggle("is-hot", true); }, easeOut, abort);
      await sleep(260); if (abort()) return;

      // 2. Click
      setStep(1);
      click(BTN.x, BTN.y);
      await sleep(700); if (abort()) return;
      btn.classList.remove("is-hot");

      // 3. Scroll (two fingers)
      setStep(2);
      if (!await moveFinger(BTN, PHOTOS, 700, { x: 180, y: 190 })) return;
      hideHalos();
      const sA = { x: 100, y: 180 }, sB = { x: 140, y: 176 };
      await tween(220, t => { halo(1, sA.x, sA.y, true, lerp(.6, 1, t)); halo(2, sB.x, sB.y, true, lerp(.6, 1, t)); }, easeOut, abort);
      if (abort()) return;
      let ok = await tween(1100, t => {
        const dy = -85 * t;
        halo(1, sA.x, sA.y + dy, true); halo(2, sB.x, sB.y + dy, true);
        photoScroll.style.setProperty("--scroll", (-150 * t) + "px");
      }, easeInOut, abort);
      if (!ok) return;
      halos[1].classList.remove("is-on"); halos[2].classList.remove("is-on");
      ok = await tween(700, t => photoScroll.style.setProperty("--scroll", (-150 - 70 * t) + "px"), easeOut, abort);   // momentum
      if (!ok) return;
      await sleep(300); if (abort()) return;

      // 4. Zoom (pinch out, then back)
      setStep(3);
      const zA = { x: 120, y: 130 }, zB = { x: 160, y: 150 };
      await tween(220, t => { halo(1, zA.x, zA.y, true, lerp(.6, 1, t)); halo(2, zB.x, zB.y, true, lerp(.6, 1, t)); }, easeOut, abort);
      ok = await tween(1100, t => {
        halo(1, zA.x - 55 * t, zA.y - 42 * t, true); halo(2, zB.x + 65 * t, zB.y + 48 * t, true);
        grid.style.setProperty("--zoom", (1 + .55 * t).toFixed(3));
      }, easeInOut, abort);
      if (!ok) return;
      await sleep(500); if (abort()) return;
      ok = await tween(800, t => {
        halo(1, zA.x - 55 * (1 - t), zA.y - 42 * (1 - t), true); halo(2, zB.x + 65 * (1 - t), zB.y + 48 * (1 - t), true);
        grid.style.setProperty("--zoom", (1.55 - .55 * t).toFixed(3));
      }, easeInOut, abort);
      if (!ok) return;
      halos[1].classList.remove("is-on"); halos[2].classList.remove("is-on");
      await sleep(300); if (abort()) return;

      // 5. Spaces (three-finger swipe left, then back)
      setStep(4);
      const f = [{ x: 210, y: 140 }, { x: 265, y: 128 }, { x: 320, y: 140 }];
      await tween(220, t => f.forEach((p, i) => halo(i + 1, p.x, p.y, true, lerp(.5, .85, t))), easeOut, abort);
      let switched = false;
      ok = await tween(1000, t => {
        f.forEach((p, i) => halo(i + 1, p.x - 170 * t, p.y, true, .85));
        if (t > .38 && !switched) { switched = true; desk.classList.add("is-space-b"); }
      }, easeInOut, abort);
      if (!ok) return;
      halos.slice(1).forEach(h => h.classList.remove("is-on"));
      await sleep(1500); if (abort()) return;
      await tween(220, t => f.forEach((p, i) => halo(i + 1, p.x - 170, p.y, true, lerp(.5, .85, t))), easeOut, abort);
      switched = false;
      ok = await tween(1000, t => {
        f.forEach((p, i) => halo(i + 1, p.x - 170 + 170 * t, p.y, true, .85));
        if (t > .38 && !switched) { switched = true; desk.classList.remove("is-space-b"); }
      }, easeInOut, abort);
      if (!ok) return;
      halos.slice(1).forEach(h => h.classList.remove("is-on"));
      await sleep(900);
    }

    async function loop() {
      for (;;) {
        await waitIdle();
        if (!userActive()) { hideHalos(); hint.classList.remove("is-hidden"); }
        await run();
        await sleep(200);
      }
    }

    if (reduced) {
      halo(0, 180, 130, true); fingerToPointer(180, 130); setStep(0);
    } else {
      loop();
    }
  })();

  /* ------------------------------------------------------------------
     Hero glow follows the cursor, gently
     ------------------------------------------------------------------ */
  (function glow() {
    const g = $(".hero__glow"); if (!g || reduced || matchMedia("(hover: none)").matches) return;
    let tx = 0, ty = 0, cx = 0, cy = 0, raf = 0;
    const step = () => { cx = lerp(cx, tx, .06); cy = lerp(cy, ty, .06); g.style.transform = `translate(calc(-50% + ${cx.toFixed(1)}px), ${cy.toFixed(1)}px)`; if (Math.abs(cx - tx) > .2 || Math.abs(cy - ty) > .2) raf = requestAnimationFrame(step); else raf = 0; };
    addEventListener("pointermove", e => { tx = (e.clientX / innerWidth - .5) * 90; ty = (e.clientY / innerHeight - .5) * 40; if (!raf) raf = requestAnimationFrame(step); }, { passive: true });
  })();

  /* ------------------------------------------------------------------
     Pseudo QR code (looks like a code, scans nothing)
     ------------------------------------------------------------------ */
  function qrSVG(seed = 7) {
    const n = 25;
    let s = seed >>> 0;
    const rnd = () => { s += 0x6D2B79F5; let t = Math.imul(s ^ (s >>> 15), 1 | s); t ^= t + Math.imul(t ^ (t >>> 7), 61 | t); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
    const m = Array.from({ length: n }, () => Array(n).fill(0));
    const finder = (ox, oy) => {
      for (let y = -1; y <= 7; y++) for (let x = -1; x <= 7; x++) {
        const X = ox + x, Y = oy + y; if (X < 0 || Y < 0 || X >= n || Y >= n) continue;
        const ring = (x === 0 || x === 6 || y === 0 || y === 6) && x >= 0 && x <= 6 && y >= 0 && y <= 6;
        const core = x >= 2 && x <= 4 && y >= 2 && y <= 4;
        m[Y][X] = (ring || core) ? 1 : 0;
      }
    };
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) m[y][x] = rnd() < .46 ? 1 : 0;
    for (let i = 8; i < n - 8; i++) { m[6][i] = i % 2 === 0 ? 1 : 0; m[i][6] = i % 2 === 0 ? 1 : 0; }
    finder(0, 0); finder(n - 7, 0); finder(0, n - 7);
    let d = "";
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (m[y][x]) d += `M${x} ${y}h1v1h-1z`;
    return `<svg viewBox="0 0 ${n} ${n}" shape-rendering="crispEdges"><path d="${d}" fill="#000"/></svg>`;
  }
  const qr = $("#qr"); if (qr) { qr.innerHTML = qrSVG(7); const c = $("#camQr"); if (c) c.innerHTML = qr.innerHTML; }

  /* ------------------------------------------------------------------
     Pairing: scroll-driven story
     ------------------------------------------------------------------ */
  (function pairing() {
    const section = $("#pair"); if (!section) return;
    const stage = $("#pairStage");
    const steps = $$("#pairSteps .step");
    const bar = $("#pairBar");
    const mobile = matchMedia("(max-width: 1000px)");

    const apply = (stepIdx, locked) => {
      stage.classList.toggle("is-step-0", stepIdx === 0);
      stage.classList.toggle("is-step-1", stepIdx === 1);
      stage.classList.toggle("is-step-2", stepIdx === 2);
      stage.classList.toggle("is-locked", !!locked);
      steps.forEach((s, i) => s.classList.toggle("is-active", i === stepIdx));
    };

    let raf = 0;
    const onScroll = () => {
      if (raf) return;
      raf = requestAnimationFrame(() => {
        raf = 0;
        const r = section.getBoundingClientRect();
        const total = section.offsetHeight - innerHeight;
        const p = clamp(-r.top / total, 0, 1);
        bar.style.width = (p * 100).toFixed(1) + "%";
        const idx = p < .28 ? 0 : p < .64 ? 1 : 2;
        apply(idx, p > .44);
      });
    };

    let timer = 0;
    const startAuto = () => {
      if (timer) return;
      let i = 0; apply(0, false);
      timer = setInterval(() => { i = (i + 1) % 4; const idx = Math.min(i, 2); apply(idx, i >= 2); }, 2600);
    };
    const stopAuto = () => { clearInterval(timer); timer = 0; };

    const setup = () => {
      removeEventListener("scroll", onScroll); stopAuto();
      if (mobile.matches || reduced) {
        if (reduced) { apply(2, true); return; }
        new IntersectionObserver(([e]) => e.isIntersecting ? startAuto() : stopAuto(), { threshold: .3 }).observe(stage);
      } else {
        addEventListener("scroll", onScroll, { passive: true }); onScroll();
      }
    };
    mobile.addEventListener("change", setup);
    setup();
  })();

  /* ------------------------------------------------------------------
     Precision: acceleration curve (Apple's parametric model, illustrated)
     ------------------------------------------------------------------ */
  (function curve() {
    const svg = $("#curve"); if (!svg) return;
    const path = $("#curvePath"), fill = $("#curveFillPath"), lin = $("#curveLinear"), dot = $("#curveDot"), gridG = $("#curveGrid");
    const input = $("#speed"), out = $("#speedVal");
    const W = 640, H = 400, L = 64, R = 24, T = 30, B = 44;
    const VMAX = 24, YMAX = 140;
    const X = v => L + v / VMAX * (W - L - R);
    const Y = y => H - B - clamp(y, 0, YMAX) / YMAX * (H - T - B);

    // Curve families by tracking-speed index (illustrative parameters)
    const K = [
      { i: 0, GL: .5, GP: .2, TSL: 6, TSPR: 12 },
      { i: 1, GL: 1.0, GP: .55, TSL: 5, TSPR: 9 },
      { i: 2, GL: 1.4, GP: .8, TSL: 4, TSPR: 8 },
      { i: 3, GL: 1.9, GP: 1.1, TSL: 3, TSPR: 7 },
    ];
    const pick = idx => {
      let a = K[0], b = K[0];
      for (const k of K) { if (k.i <= idx) a = k; }
      b = K[Math.min(K.indexOf(a) + 1, K.length - 1)];
      const r = b.i === a.i ? 0 : (idx - a.i) / (b.i - a.i);
      const o = {}; for (const key of ["GL", "GP", "TSL", "TSPR"]) o[key] = lerp(a[key], b[key], r);
      return o;
    };
    const model = c => {
      const f1 = v => c.GL * v + Math.pow(c.GP * v, 2);
      const y0 = f1(c.TSL), m0 = c.GL + 2 * c.TSL * c.GP * c.GP, b0 = y0 - m0 * c.TSL;
      const y1 = m0 * c.TSPR + b0, m1 = 2 * y1 * m0, b1 = y1 * y1 - m1 * c.TSPR;
      return v => v <= c.TSL ? f1(v) : v <= c.TSPR ? m0 * v + b0 : Math.sqrt(Math.max(0, m1 * v + b1));
    };

    // grid
    let g = "";
    for (let i = 1; i <= 6; i++) { const x = X(i * VMAX / 6); g += `<line x1="${x}" y1="${T}" x2="${x}" y2="${H - B}"/>`; }
    for (let i = 1; i <= 4; i++) { const y = Y(i * YMAX / 4); g += `<line x1="${L}" y1="${y}" x2="${W - R}" y2="${y}"/>`; }
    gridG.innerHTML = g;
    lin.setAttribute("d", `M${X(0)} ${Y(0)} L${X(VMAX)} ${Y(VMAX * 2)}`);

    let current = parseFloat(input.value), shown = current;
    const draw = idx => {
      const f = model(pick(idx));
      let d = "", pts = [];
      for (let i = 0; i <= 80; i++) { const v = i / 80 * VMAX; const x = X(v), y = Y(f(v)); pts.push([x, y]); d += (i ? " L" : "M") + x.toFixed(1) + " " + y.toFixed(1); }
      path.setAttribute("d", d);
      fill.setAttribute("d", d + ` L${X(VMAX)} ${Y(0)} L${X(0)} ${Y(0)} Z`);
      const vd = 10; dot.setAttribute("cx", X(vd)); dot.setAttribute("cy", Y(f(vd)));
      if (readout) readout.textContent = `${vd} mm/s → ${(f(vd) / (vd * 2)).toFixed(2)}×`;
    };
    const readout = $("#curveReadout");
    const setFill = () => input.style.setProperty("--fill", (parseFloat(input.value) / 3 * 100).toFixed(1) + "%");
    const labelFor = v => { const tick = Math.round(v / 3 * 9) + 1; return tick === 4 ? "Default" : tick + " / 10"; };
    const update = () => {
      setFill();
      current = parseFloat(input.value); out.textContent = labelFor(current);
      if (reduced) { shown = current; draw(shown); return; }
      const from = shown; tween(380, t => { shown = lerp(from, current, t); draw(shown); }, easeOut);
    };
    input.addEventListener("input", update);
    setFill(); draw(shown); out.textContent = labelFor(current);
  })();

  /* ------------------------------------------------------------------
     Stats: count up
     ------------------------------------------------------------------ */
  (function stats() {
    const els = $$("[data-count]"); if (!els.length) return;
    const io = new IntersectionObserver(entries => {
      entries.forEach(e => {
        if (!e.isIntersecting) return; io.unobserve(e.target);
        const target = parseFloat(e.target.dataset.count);
        if (reduced || target === 0) { e.target.textContent = target; return; }
        tween(1300, t => { e.target.textContent = Math.round(target * t); }, easeOut);
      });
    }, { threshold: .6 });
    els.forEach(el => io.observe(el));
  })();

  /* ------------------------------------------------------------------
     Themes
     ------------------------------------------------------------------ */
  (function themes() {
    const seg = $(".seg"); if (!seg) return;
    const glass = $("#themeGlass"), hero = $("#heroGlass");
    const buttons = $$("button[data-theme]", seg);
    const select = (b, focus = false) => {
      buttons.forEach(x => { const on = x === b; x.setAttribute("aria-checked", String(on)); x.tabIndex = on ? 0 : -1; });
      glass.dataset.theme = b.dataset.theme; if (hero) hero.dataset.theme = b.dataset.theme;
      if (focus) b.focus();
    };
    seg.addEventListener("click", e => { const b = e.target.closest("button[data-theme]"); if (b) select(b); });
    seg.addEventListener("keydown", e => {
      const i = buttons.indexOf(document.activeElement); if (i < 0) return;
      const delta = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
      if (delta) { e.preventDefault(); select(buttons[(i + delta + buttons.length) % buttons.length], true); }
      if (e.key === "Home") { e.preventDefault(); select(buttons[0], true); }
      if (e.key === "End") { e.preventDefault(); select(buttons[buttons.length - 1], true); }
    });
  })();

  /* ------------------------------------------------------------------
     Repo links: <html data-repo="owner/name"> rewrites every OWNER placeholder
     ------------------------------------------------------------------ */
  (function links() {
    // App Store buttons stay inert (no broken link) until APPSTORE_URL is filled in.
    $$("a[href='APPSTORE_URL']").forEach(a => {
      a.removeAttribute("href"); a.classList.add("is-soon"); a.setAttribute("aria-disabled", "true"); a.setAttribute("role", "link");
      a.querySelector("svg")?.remove();
      a.insertAdjacentHTML("beforeend", '<span class="btn__soon">App Store · soon</span>');
    });
    const repo = document.documentElement.dataset.repo;
    if (!repo || repo.startsWith("OWNER")) return;
    $$("a[href*='github.com/OWNER/trackglass']").forEach(a => { a.href = a.href.replace("OWNER/trackglass", repo); });
  })();
})();
