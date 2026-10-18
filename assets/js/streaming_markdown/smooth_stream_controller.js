const DEFAULT_OPTIONS = {
  minCharsPerSecond: 40,
  maxCharsPerSecond: 1000,
  targetLatencyMs: 900,
  catchUpLatencyMs: 350,
  catchUpThreshold: 600,
  maxCommitFps: 30,
  startDelayMs: 80,
  maxCharsPerCommit: 80,
  flushOnFinish: false
};

export function createSmoothMarkdownStream(options = {}, notify) {
  const config = normalizeOptions({ ...DEFAULT_OPTIONS, ...options });
  const listeners = new Set();
  if (typeof notify === "function") listeners.add(notify);

  let source = "";
  let visible = "";
  let done = false;
  let paused = false;
  let destroyed = false;
  let rafId = 0;
  let startedAt = 0;
  let lastTick = 0;
  let charBudget = 0;
  let currentCps = config.minCharsPerSecond;
  let hasStarted = false;
  let fenceHoldEnd = null;
  const segmenter = createGraphemeSegmenter();

  const revealLimit = () =>
    fenceHoldEnd == null || done ? source.length : Math.min(fenceHoldEnd, source.length);
  const pendingChars = () => Math.max(0, revealLimit() - visible.length);
  const caughtUp = () => pendingChars() === 0;
  const final = () => done && caughtUp();

  function getSnapshot() {
    return { source, visible, done, paused, pendingChars: pendingChars(), caughtUp: caughtUp(), final: final() };
  }

  function subscribe(listener) {
    if (destroyed) return () => {};
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  function enqueue(chunk) {
    if (destroyed || !chunk) return;
    if (done) done = false;

    const hadSource = source.length > 0;
    const wasIdle = pendingChars() <= 0;
    source += String(chunk);
    fenceHoldEnd = withheldFenceEnd(source);

    if (wasIdle) {
      const t = now();
      startedAt = hadSource && hasStarted ? t - config.startDelayMs : t;
      lastTick = t;
      charBudget = 0;
    }

    hasStarted = true;
    emit();
    ensureLoop();
  }

  function finish(finishOptions = {}) {
    if (destroyed) return;
    done = true;
    if (finishOptions.flush ?? config.flushOnFinish) {
      fenceHoldEnd = null;
      visible = source;
      charBudget = 0;
      currentCps = config.minCharsPerSecond;
      cancelLoop();
      emit();
      return;
    }
    emit();
    ensureLoop();
  }

  function flush() {
    if (destroyed) return;
    fenceHoldEnd = done ? null : withheldFenceEnd(source);
    visible = source.slice(0, revealLimit());
    charBudget = 0;
    currentCps = config.minCharsPerSecond;
    cancelLoop();
    emit();
  }

  function reset(initialMarkdown = "") {
    if (destroyed) return;
    cancelLoop();
    source = String(initialMarkdown);
    fenceHoldEnd = withheldFenceEnd(source);
    visible = source;
    done = false;
    paused = false;
    hasStarted = false;
    startedAt = 0;
    lastTick = 0;
    charBudget = 0;
    currentCps = config.minCharsPerSecond;
    emit();
  }

  function pause() {
    if (destroyed || paused) return;
    paused = true;
    cancelLoop();
    emit();
  }

  function resume() {
    if (destroyed || !paused) return;
    paused = false;
    const t = now();
    lastTick = t;
    startedAt ||= t;
    emit();
    ensureLoop();
  }

  function destroy() {
    if (destroyed) return;
    destroyed = true;
    cancelLoop();
    listeners.clear();
  }

  function ensureLoop() {
    if (destroyed || rafId || paused || pendingChars() <= 0) return;
    if (typeof requestAnimationFrame !== "function") {
      flush();
      return;
    }
    rafId = requestAnimationFrame(tick);
  }

  function tick(timestamp) {
    rafId = 0;
    if (destroyed || paused) return;

    if (pendingChars() <= 0) {
      startedAt = 0;
      lastTick = 0;
      charBudget = 0;
      currentCps = config.minCharsPerSecond;
      return;
    }

    if (timestamp - startedAt < config.startDelayMs) {
      rafId = requestAnimationFrame(tick);
      return;
    }

    const minFrameMs = 1000 / Math.max(1, config.maxCommitFps);
    const dt = Math.min(100, Math.max(0, timestamp - lastTick));
    if (dt < minFrameMs) {
      rafId = requestAnimationFrame(tick);
      return;
    }

    lastTick = timestamp;
    const pending = pendingChars();
    const latencyMs = pending > config.catchUpThreshold ? config.catchUpLatencyMs : config.targetLatencyMs;
    const targetCps = clamp(pending / Math.max(0.001, latencyMs / 1000), config.minCharsPerSecond, config.maxCharsPerSecond);
    currentCps += (targetCps - currentCps) * 0.2;
    charBudget += currentCps * (dt / 1000);

    if (charBudget < 1) {
      ensureLoop();
      return;
    }

    const desiredCount = Math.min(Math.floor(charBudget), config.maxCharsPerCommit);
    const rest = source.slice(visible.length, revealLimit());
    const nextSlice = takeGraphemes(rest, desiredCount, segmenter);

    if (nextSlice.text) {
      visible += nextSlice.text;
      charBudget = Math.max(0, charBudget - nextSlice.graphemeCount);
      emit();
    }

    ensureLoop();
  }

  function cancelLoop() {
    if (!rafId) return;
    if (typeof cancelAnimationFrame === "function") cancelAnimationFrame(rafId);
    rafId = 0;
  }

  function emit() {
    if (destroyed) return;
    for (const listener of [...listeners]) listener();
  }

  return { getSnapshot, subscribe, enqueue, finish, flush, reset, pause, resume, destroy, dispose: destroy };
}

function normalizeOptions(options) {
  return {
    minCharsPerSecond: positiveFinite(options.minCharsPerSecond, 40, 1),
    maxCharsPerSecond: Math.max(positiveFinite(options.minCharsPerSecond, 40, 1), positiveFinite(options.maxCharsPerSecond, 1000, 1)),
    targetLatencyMs: positiveFinite(options.targetLatencyMs, 900, 1),
    catchUpLatencyMs: positiveFinite(options.catchUpLatencyMs, 350, 1),
    catchUpThreshold: nonNegativeFinite(options.catchUpThreshold, 600),
    maxCommitFps: Math.trunc(positiveFinite(options.maxCommitFps, 30, 1)),
    startDelayMs: nonNegativeFinite(options.startDelayMs, 80),
    maxCharsPerCommit: Math.trunc(positiveFinite(options.maxCharsPerCommit, 80, 1)),
    flushOnFinish: Boolean(options.flushOnFinish)
  };
}

function positiveFinite(value, fallback, min = 1) {
  const normalized = Number(value);
  return Number.isFinite(normalized) ? Math.max(min, normalized) : fallback;
}

function nonNegativeFinite(value, fallback) {
  const normalized = Number(value);
  return Number.isFinite(normalized) ? Math.max(0, normalized) : fallback;
}

function createGraphemeSegmenter() {
  if (typeof Intl === "undefined" || typeof Intl.Segmenter !== "function") return null;
  return new Intl.Segmenter(undefined, { granularity: "grapheme" });
}

function takeGraphemes(input, count, segmenter) {
  if (!input || count <= 0) return { text: "", graphemeCount: 0 };
  if (!segmenter) {
    const parts = Array.from(input).slice(0, count);
    return { text: parts.join(""), graphemeCount: parts.length };
  }

  let text = "";
  let graphemeCount = 0;
  for (const part of segmenter.segment(input)) {
    if (graphemeCount >= count) break;
    text += part.segment;
    graphemeCount++;
  }
  return { text, graphemeCount };
}

function now() {
  return typeof performance !== "undefined" ? performance.now() : Date.now();
}

function withheldFenceEnd(source) {
  const lastLineBreak = source.lastIndexOf("\n");
  const line = lastLineBreak === -1 ? source : source.slice(lastLineBreak + 1);
  if (!/^[ \t]*(`{3,}|~{3,})/.test(line)) return null;
  return lastLineBreak === -1 ? 0 : lastLineBreak + 1;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
