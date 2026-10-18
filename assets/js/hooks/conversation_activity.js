const conversationColors = [
  "#e4bd3f", "#ed9438", "#e66c55", "#dc5362",
  "#d878a1", "#c75dae", "#8b79d8", "#6c9add",
  "#3ebd79", "#89c351", "#c78049", "#af6c59",
];

// Mix all hash bits before selecting a color, rather than just FNV's low bits.
function conversationHash(id) {
  let hash = 2166136261;
  for (const ch of id) hash = Math.imul(hash ^ ch.codePointAt(0), 16777619);
  hash = Math.imul(hash ^ (hash >>> 16), 0x85ebca6b);
  hash = Math.imul(hash ^ (hash >>> 13), 0xc2b2ae35);
  return (hash ^ (hash >>> 16)) >>> 0;
}

// Runtime owns running/waiting/idle; the 7.6-second sequence is purely visual.
const cycleDuration = 7.6;
const appearanceDuration = 0.8;
export const ConversationActivity = {
  mounted() {
    this.bodies = new Map();
    this.visibility = new Map();
    this.paintedPoses = new WeakMap();
    this.paintedAppearances = new WeakMap();
    this.observer = typeof IntersectionObserver === "function"
      ? new IntersectionObserver(entries => this.onIntersection(entries)) : null;
    this.motion = matchMedia("(prefers-reduced-motion: reduce)");
    this.onVisibility = () => {
      const now = performance.now();
      for (const body of this.bodies.values()) {
        this.catchUp(body, now);
        body.offscreenAt = !document.hidden && !this.motion.matches && body.state === "running" &&
          !body.visibleSprites.length ? now : null;
      }
      this.schedule();
    };
    this.onMotion = () => this.sync();
    document.addEventListener("visibilitychange", this.onVisibility);
    this.motion.addEventListener("change", this.onMotion);
    this.sync();
  },

  updated() { this.sync(); },

  destroyed() {
    cancelAnimationFrame(this.frame);
    this.observer?.disconnect();
    this.visibility.clear();
    document.removeEventListener("visibilitychange", this.onVisibility);
    this.motion.removeEventListener("change", this.onMotion);
  },

  sync() {
    const next = new Map();
    const seen = new Set();
    const now = performance.now();
    for (const body of this.bodies.values()) this.catchUp(body, now);
    // A LiveView patch can replace styles on a retained element.
    this.paintedPoses = new WeakMap();
    this.paintedAppearances = new WeakMap();
    for (const el of this.el.querySelectorAll("[data-run-id]")) {
      const id = el.dataset.runId;
      const hash = conversationHash(id);
      const body = next.get(id) || this.bodies.get(id) || { elapsed: 0, growth: 0 };
      const sprite = el.querySelector(".conversation-run-sprite");
      if (!sprite) continue;
      // Keep phase across LiveView patches and approval; reset after completion.
      if (body.state === "idle") {
        body.elapsed = 0;
        body.growth = 0;
      }
      body.state = el.dataset.runState;
      if (body.state === "idle") body.growth = 0;
      if (body.state === "running" && this.motion.matches) body.growth = 1;
      if (!next.has(id)) {
        body.sprites = [];
        body.indicators = [];
      }
      body.sprites.push(sprite);
      body.indicators.push(el);
      // Idle stems are static; only active indicators need visibility tracking.
      if (body.state !== "idle") {
        seen.add(el);
        if (!this.visibility.has(el)) {
          this.visibility.set(el, true);
          this.observer?.observe(el);
        }
      }
      el.style.setProperty("--run-color", conversationColors[hash % conversationColors.length]);
      next.set(id, body);
    }
    for (const el of this.visibility.keys()) {
      if (seen.has(el)) continue;
      this.observer?.unobserve(el);
      this.visibility.delete(el);
    }
    this.bodies = next;
    this.runningBodies = [...next.values()].filter(body => body.state === "running");
    for (const body of this.bodies.values()) {
      this.updateVisible(body);
      body.offscreenAt = !document.hidden && !this.motion.matches && body.state === "running" &&
        !body.visibleSprites.length ? now : null;
      this.paintAppearance(body);
      this.paint(body);
    }
    this.schedule();
  },

  schedule() {
    if (document.hidden || this.motion.matches ||
        !this.runningBodies.some(body => body.visibleSprites.length)) {
      cancelAnimationFrame(this.frame);
      this.frame = null;
      return;
    }
    if (this.frame) return;
    this.last = performance.now();
    this.frame = requestAnimationFrame(now => this.tick(now));
  },

  updateVisible(body) {
    body.visibleIndicators = [];
    body.visibleSprites = [];
    body.indicators.forEach((el, index) => {
      if (this.visibility.get(el) === false) return;
      body.visibleIndicators.push(el);
      body.visibleSprites.push(body.sprites[index]);
    });
  },

  onIntersection(entries) {
    const now = performance.now();
    for (const entry of entries) {
      if (this.visibility.has(entry.target)) {
        this.visibility.set(entry.target, entry.isIntersecting);
      }
    }
    for (const body of this.bodies.values()) {
      this.catchUp(body, now);
      this.updateVisible(body);
      body.offscreenAt = !document.hidden && !this.motion.matches && body.state === "running" &&
        !body.visibleSprites.length ? now : null;
      if (document.hidden) continue;
      this.paintAppearance(body);
      this.paint(body);
    }
    this.schedule();
  },

  catchUp(body, now) {
    if (body.offscreenAt == null) return;
    this.advance(body, Math.max(0, (now - body.offscreenAt) / 1000));
    body.offscreenAt = null;
  },

  advance(body, dt) {
    if (body.state !== "running") return;
    let remaining = dt;
    if (body.growth < 1) {
      const consumed = Math.min(remaining, appearanceDuration * (1 - body.growth));
      body.growth = Math.min(1, body.growth + consumed / appearanceDuration);
      remaining -= consumed;
    }
    body.elapsed = (body.elapsed + remaining) % cycleDuration;
  },

  paintAppearance(body) {
    const growing = body.state === "running" && body.growth < 1 && !this.motion.matches;
    const key = growing ? body.growth : "static";
    const indicators = body.visibleIndicators.filter(el => this.paintedAppearances.get(el) !== key);
    if (!indicators.length) return;
    const flag = growing ? "true" : "false";
    const p = growing ? body.growth * body.growth * (3 - 2 * body.growth) : 0;
    const values = growing ? {
      "--run-stem-rise": `${-7 * p}px`,
      "--run-reveal-top": `${59.615 * (1 - p)}%`,
      "--run-reveal-bottom": `${40.385 * (1 - p)}%`,
      "--run-reveal-opacity": `${p}`,
      "--run-limbs-opacity": `${Math.max(0, (p - .65) / .35)}`,
    } : {};
    for (const el of indicators) {
      if (el.dataset.runGrowing !== flag) el.dataset.runGrowing = flag;
      for (const [name, value] of Object.entries(values)) {
        if (el.style.getPropertyValue(name) !== value) el.style.setProperty(name, value);
      }
      this.paintedAppearances.set(el, key);
    }
  },

  paint(body) {
    const moving = body.state === "running" && body.growth >= 1 && !this.motion.matches;
    const time = moving ? body.elapsed % cycleDuration : 0;
    const stage = time < 2 ? 0 : time < 5.6 ? 1 : 2;
    const local = stage === 0 ? time : stage === 1 ? time - 2 : time - 5.6;
    const action = stage === 1 ? "look" : "walk";
    const frame = Math.floor(local * 8) % 8;
    const p = local / 3.6;
    const lookFrame = p < .12 ? 0 : p < .20 ? 1 : p < .24 ? 2 : p < .44 ? 3 :
      p < .56 ? 4 : p < .64 ? 5 : p < .68 ? 6 : p < .88 ? 7 : 8;
    const key = !moving ? "still" : stage === 1 ? `look:${lookFrame}` : `walk:${frame}`;
    const sprites = body.visibleSprites.filter(sprite => this.paintedPoses.get(sprite) !== key);
    if (!sprites.length) return;
    if (body.pose?.key !== key) {
      const values = {
        "--run-hop": 0, "--run-upper-x": 0,
        "--run-eyes-x": 0, "--run-sway": 0,
        "--run-step-a": 0, "--run-step-b": 0,
        "--run-left-y": 0, "--run-right-y": 0,
      };
      if (moving && stage !== 1) {
        values["--run-hop"] = frame % 4 >= 2 ? -1 : 0;
        values["--run-step-a"] = frame < 4 ? 0 : -1;
        values["--run-step-b"] = frame < 4 ? -1 : 0;
        values["--run-left-y"] = values["--run-step-b"];
        values["--run-right-y"] = values["--run-step-a"];
        values["--run-sway"] = frame % 4 >= 2 ? 1 : 0;
      } else if (moving && stage === 1) {
        values["--run-eyes-x"] = p < .12 ? 0 : p < .20 ? -1 : p < .44 ? -2 : p < .56 ? 0 : p < .64 ? 1 : p < .88 ? 2 : 0;
        values["--run-upper-x"] = p >= .20 && p < .44 ? -1 : p >= .64 && p < .88 ? 1 : 0;
        values["--run-sway"] = p >= .24 && p < .44 ? -1 : p >= .68 && p < .88 ? 1 : 0;
      }
      body.pose = { key, values };
    }
    for (const sprite of sprites) {
      if (sprite.dataset.runAction !== action) sprite.dataset.runAction = action;
      for (const [name, value] of Object.entries(body.pose.values)) {
        const cssValue = `${value}px`;
        if (sprite.style.getPropertyValue(name) !== cssValue) sprite.style.setProperty(name, cssValue);
      }
      this.paintedPoses.set(sprite, key);
    }
  },

  tick(now) {
    const dt = Math.min(0.05, (now - this.last) / 1000);
    this.last = now;
    // Only render changed poses; offscreen bodies catch up lazily on re-entry.
    for (const body of this.runningBodies) {
      if (!body.visibleSprites.length) continue;
      this.advance(body, dt);
      this.paintAppearance(body);
      this.paint(body);
    }
    this.frame = null;
    this.schedule();
  },
};
