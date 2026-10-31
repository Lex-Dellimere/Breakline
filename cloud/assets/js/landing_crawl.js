// decorative background for the landing page hero: small squares rise out of
// the floor (bottom edge), crawl along it in discrete grid steps, turn the
// corner and climb the side walls, settle for a while and fade out.
//
// the room is unrolled into one path: left wall (top to bottom), floor (left
// to right), right wall (bottom to top). a square at path index t moving in
// direction -1 crawls left along the floor and keeps going up the left wall,
// +1 does the same on the right, so the corner turn falls out of the mapping.
// depth d is the distance from the surface into the room (0 = touching it).
//
// rendered only where an element carries data-crawl. the element is a canvas
// with aria-hidden; nothing on it is interactive.

const STEP_MS = 260; // tween for one grid step
const RISE_MS = 1400; // emerging from the ground
const FADE_MS = 2200;
const FRAME_MS = 1000 / 30; // frame budget: the motion is slow, 30fps is plenty
const MAX_DT = 100; // clamp sim time after a long frame or a resume
const CLIMB_FRAC = 0.72; // how far up the walls squares may climb
const ACCENT_SHARE = 0.18;

// small seeded prng so the reduced-motion arrangement is stable between loads
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const easeOut = (x) => 1 - Math.pow(1 - x, 3);
const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x);

class Crawl {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.host = canvas.parentElement;
    this.running = false;
    this.visible = true;
    this.onScreen = true;
    this.rafId = null;
    this.colors = { base: "#a1a1aa", accent: "#3b82f6" };
    this.motion = matchMedia("(prefers-reduced-motion: reduce)");

    this.frame = this.frame.bind(this);
    this.onVisibility = () => {
      this.visible = document.visibilityState === "visible";
      this.updateRunning();
    };
    this.onMotionChange = () => this.reset();
    this.onWindowResize = () => this.resize();

    this.readColors();
    this.resize(true);

    document.addEventListener("visibilitychange", this.onVisibility);
    this.motion.addEventListener("change", this.onMotionChange);
    window.addEventListener("resize", this.onWindowResize);

    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(this.host);

    this.intersection = new IntersectionObserver((entries) => {
      this.onScreen = entries.some((e) => e.isIntersecting);
      this.updateRunning();
    });
    this.intersection.observe(this.canvas);

    // follow the theme toggle (and the system scheme, which the root script
    // mirrors into data-theme)
    this.themeObserver = new MutationObserver(() => {
      this.readColors();
      this.dirty = true;
      if (this.reduced) this.drawStatic();
    });
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });
  }

  destroy() {
    this.stop();
    document.removeEventListener("visibilitychange", this.onVisibility);
    this.motion.removeEventListener("change", this.onMotionChange);
    window.removeEventListener("resize", this.onWindowResize);
    this.resizeObserver.disconnect();
    this.intersection.disconnect();
    this.themeObserver.disconnect();
  }

  readColors() {
    const style = getComputedStyle(this.canvas);
    const base = style.color;
    const accent = style.getPropertyValue("--crawl-accent").trim();
    if (base) this.colors.base = base;
    if (accent) this.colors.accent = accent;
  }

  // the canvas spans the full viewport width so the walls sit at the screen
  // edges, well away from the hero text on wide screens
  resize(force = false) {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const hostRect = this.host.getBoundingClientRect();
    const vw = document.documentElement.clientWidth;
    const top = parseFloat(getComputedStyle(this.canvas).top) || 0;
    const w = Math.max(1, Math.round(vw));
    const h = Math.max(1, Math.round(hostRect.height - top));

    this.canvas.style.left = `${-hostRect.left}px`;
    this.canvas.style.width = `${w}px`;
    this.canvas.style.height = `${h}px`;

    const sizeChanged = w !== this.w || h !== this.h || dpr !== this.dpr;
    if (!force && !sizeChanged) return;

    this.w = w;
    this.h = h;
    this.dpr = dpr;
    this.canvas.width = Math.round(w * dpr);
    this.canvas.height = Math.round(h * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    // keep wall growth inside the side gutter so it never runs under text
    this.gutterLeft = hostRect.left;
    this.gutterRight = vw - hostRect.right;
    this.reset();
  }

  setupGrid() {
    const small = this.w < 640;
    this.size = small ? 7 : 9;
    this.pitch = this.size + (small ? 3 : 4);
    this.cols = Math.max(2, Math.floor(this.w / this.pitch));
    this.rows = Math.max(2, Math.floor(this.h / this.pitch));
    // centre the grid so both walls sit the same distance from the edges
    this.ox = Math.floor((this.w - this.cols * this.pitch) / 2) + 2;
    this.oy = this.h - this.rows * this.pitch;

    this.wallH = this.rows - 1; // the bottom row is the floor
    this.floorW = this.cols;
    this.pathLen = this.wallH * 2 + this.floorW;
    this.minRow = Math.floor(this.wallH * (1 - CLIMB_FRAC));
    this.floorDepth = Math.min(3, this.rows - 1);
    const gutter = Math.min(this.gutterLeft, this.gutterRight);
    this.wallDepth = Math.max(1, Math.min(4, Math.floor(gutter / this.pitch)));

    this.occ = new Int32Array(this.cols * this.rows);
    this.cap = Math.max(24, Math.min(180, Math.round(this.pathLen * (small ? 0.45 : 0.7))));
  }

  reset() {
    this.stop();
    this.setupGrid();
    this.rand = mulberry32(0xb4e41);
    this.squares = [];
    this.nextId = 1;
    this.now = 0;
    this.nextSpawn = 0;
    this.spawned = 0;
    this.dirty = true;
    this.reduced = this.motion.matches;

    if (this.reduced) {
      this.prerun(70000);
      this.drawStatic();
    } else {
      // start with a sparse colony so the page is never bare
      this.prerun(40000);
      this.draw();
      this.updateRunning();
    }
  }

  // path index + depth -> grid cell, or null when off the surface
  cellAt(t, d) {
    if (t < 0 || t >= this.pathLen || d < 0) return null;
    let col;
    let row;
    if (t < this.wallH) {
      if (d >= this.wallDepth) return null;
      col = d;
      row = t;
    } else if (t < this.wallH + this.floorW) {
      if (d >= this.floorDepth) return null;
      col = t - this.wallH;
      row = this.rows - 1 - d;
    } else {
      if (d >= this.wallDepth) return null;
      col = this.cols - 1 - d;
      row = this.wallH - 1 - (t - this.wallH - this.floorW);
    }
    if (row < this.minRow) return null;
    return { col, row, idx: row * this.cols + col };
  }

  free(cell) {
    return cell !== null && this.occ[cell.idx] === 0;
  }

  px(cell) {
    return {
      x: this.ox + cell.col * this.pitch,
      y: this.oy + cell.row * this.pitch,
    };
  }

  spawn() {
    const r = this.rand;
    // spawn mostly near the corners so the growth gathers where floor meets
    // wall and thins out towards the middle of the room
    const half = this.floorW / 2;
    const fromWall = Math.floor(Math.pow(r(), 2.2) * half);
    const left = r() < 0.5;
    const t = this.wallH + (left ? fromWall : this.floorW - 1 - fromWall);
    let cell = null;
    let d = 0;
    for (; d < this.floorDepth; d++) {
      const c = this.cellAt(t, d);
      if (this.free(c)) {
        cell = c;
        break;
      }
    }
    if (!cell) return;

    // most squares head for the nearer wall
    const toLeft = t - this.wallH < this.floorW / 2;
    const dir = r() < 0.75 ? (toLeft ? -1 : 1) : toLeft ? 1 : -1;
    const p = this.px(cell);
    const sq = {
      id: this.nextId++,
      t,
      d,
      cell,
      dir,
      x: p.x,
      y: p.y,
      fx: p.x,
      fy: p.y + this.pitch, // rise from the cell below (under the ground)
      moveAt: this.now,
      moveMs: RISE_MS,
      born: this.now,
      state: "rising",
      nextAt: this.now + RISE_MS + 300 + r() * 900,
      life: 40000 + r() * 50000,
      alpha: 0.45 + r() * 0.45,
      accent: r() < ACCENT_SHARE,
      steps: 0,
      blocked: 0,
      fadeAt: 0,
    };
    this.occ[cell.idx] = sq.id;
    this.squares.push(sq);
    this.spawned++;
  }

  moveTo(sq, t, d, cell) {
    this.occ[sq.cell.idx] = 0;
    this.occ[cell.idx] = sq.id;
    const p = this.px(cell);
    sq.fx = sq.x;
    sq.fy = sq.y;
    sq.x = p.x;
    sq.y = p.y;
    sq.t = t;
    sq.d = d;
    sq.cell = cell;
    sq.moveAt = this.now;
    sq.moveMs = STEP_MS;
    sq.steps++;
    sq.blocked = 0;
  }

  step(sq) {
    const r = this.rand;
    const nt = sq.t + sq.dir;

    // prefer hugging the surface, then straight on, then climbing over
    const options = [];
    if (sq.d > 0 && r() < 0.6) options.push([nt, sq.d - 1]);
    options.push([nt, sq.d]);
    if (r() < 0.5) options.push([nt, sq.d + 1]);
    else options.push([sq.t, sq.d + 1]);

    for (const [t, d] of options) {
      const cell = this.cellAt(t, d);
      if (this.free(cell)) {
        this.moveTo(sq, t, d, cell);
        return true;
      }
    }
    sq.blocked++;
    return false;
  }

  tick(dt) {
    this.now += dt;
    const now = this.now;
    const r = this.rand;

    if (now >= this.nextSpawn && this.squares.length < this.cap) {
      this.spawn();
      const warm = this.spawned < 12;
      this.nextSpawn = now + (warm ? 200 + r() * 300 : 350 + r() * 650);
    }

    let removed = false;
    for (const sq of this.squares) {
      if (sq.state === "rising" && now - sq.moveAt >= RISE_MS) {
        sq.state = "crawling";
      }

      if (sq.state === "crawling" && now >= sq.nextAt) {
        const moved = this.step(sq);
        // reaching the top of the climb, getting stuck, or just deciding to
        // stop all turn a crawler into a settled tile of the growth
        const atTop = this.cellAt(sq.t + sq.dir, 0) === null && sq.t !== this.wallH;
        const tired = moved && sq.steps > 4 && r() < 0.035;
        if ((moved && atTop) || sq.blocked > 3 || tired) {
          sq.state = "settled";
        } else {
          const pause = r() < 0.12;
          sq.nextAt = now + (pause ? 2500 + r() * 3500 : 500 + r() * 900);
        }
        this.dirty = true;
      }

      if (sq.state !== "fading" && now - sq.born >= sq.life) {
        sq.state = "fading";
        sq.fadeAt = now;
      }

      if (sq.state === "fading" && now - sq.fadeAt >= FADE_MS) {
        this.occ[sq.cell.idx] = 0;
        sq.dead = true;
        removed = true;
      }

      if (sq.state === "rising" || sq.state === "fading") this.dirty = true;
      if (now - sq.moveAt < sq.moveMs) this.dirty = true;
    }
    if (removed) this.squares = this.squares.filter((s) => !s.dead);
  }

  prerun(ms) {
    for (let elapsed = 0; elapsed < ms; elapsed += MAX_DT) this.tick(MAX_DT);
  }

  // fade with height on the walls so the growth thins out as it climbs
  fieldAlpha(sq) {
    if (sq.t >= this.wallH && sq.t < this.wallH + this.floorW) return 1;
    const climb = (this.wallH - sq.cell.row) / Math.max(1, this.wallH - this.minRow);
    return 1 - 0.65 * clamp01(climb);
  }

  paint(sq, x, y, scale, alpha) {
    const ctx = this.ctx;
    const s = this.size * scale;
    const off = (this.size - s) / 2;
    ctx.globalAlpha = alpha;
    ctx.fillStyle = sq.accent ? this.colors.accent : this.colors.base;
    ctx.fillRect(x + off, y + off, s, s);
  }

  draw() {
    const ctx = this.ctx;
    const now = this.now;
    ctx.clearRect(0, 0, this.w, this.h);

    for (const sq of this.squares) {
      const k = sq.moveMs > 0 ? easeOut(clamp01((now - sq.moveAt) / sq.moveMs)) : 1;
      const x = sq.fx + (sq.x - sq.fx) * k;
      const y = sq.fy + (sq.y - sq.fy) * k;
      let alpha = sq.alpha * this.fieldAlpha(sq);
      let scale = 1;

      if (sq.state === "rising") {
        alpha *= k;
        scale = 0.35 + 0.65 * k;
      } else if (sq.state === "fading") {
        const f = clamp01((now - sq.fadeAt) / FADE_MS);
        alpha *= 1 - f;
        scale = 1 - 0.4 * f;
      }
      if (alpha > 0.01) this.paint(sq, x, y, scale, alpha);
    }
    ctx.globalAlpha = 1;
    this.dirty = false;
  }

  // reduced motion: one still frame of a grown colony, no tweens
  drawStatic() {
    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.w, this.h);
    for (const sq of this.squares) {
      if (sq.state === "fading") continue;
      this.paint(sq, sq.x, sq.y, 1, sq.alpha * this.fieldAlpha(sq));
    }
    ctx.globalAlpha = 1;
  }

  updateRunning() {
    const should = !this.reduced && this.visible && this.onScreen;
    if (should && !this.running) this.start();
    else if (!should && this.running) this.stop();
  }

  start() {
    this.running = true;
    this.lastTs = null;
    this.lastDraw = 0;
    this.rafId = requestAnimationFrame(this.frame);
  }

  stop() {
    this.running = false;
    if (this.rafId !== null) cancelAnimationFrame(this.rafId);
    this.rafId = null;
  }

  frame(ts) {
    if (!this.running) return;
    this.rafId = requestAnimationFrame(this.frame);
    if (this.lastTs === null) {
      this.lastTs = ts;
      this.lastDraw = ts;
      return;
    }
    if (ts - this.lastDraw < FRAME_MS - 1) return;
    const dt = Math.min(ts - this.lastTs, MAX_DT);
    this.lastTs = ts;
    this.lastDraw = ts;
    this.tick(dt);
    if (this.dirty) this.draw();
  }
}

export function mountCrawls(root = document) {
  root.querySelectorAll("canvas[data-crawl]").forEach((canvas) => {
    if (canvas.crawl || !canvas.getContext) return;
    canvas.crawl = new Crawl(canvas);
  });
}

export function unmountCrawls(root = document) {
  root.querySelectorAll("canvas[data-crawl]").forEach((canvas) => {
    if (!canvas.crawl) return;
    canvas.crawl.destroy();
    canvas.crawl = null;
  });
}
