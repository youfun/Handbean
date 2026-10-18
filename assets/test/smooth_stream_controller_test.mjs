import assert from "node:assert/strict";
import { createSmoothMarkdownStream } from "../js/streaming_markdown/smooth_stream_controller.js";

function installRaf() {
  let nextId = 1;
  const callbacks = new Map();
  globalThis.requestAnimationFrame = (cb) => {
    const id = nextId++;
    callbacks.set(id, cb);
    return id;
  };
  globalThis.cancelAnimationFrame = (id) => callbacks.delete(id);
  return {
    step(time = 100) {
      const pending = [...callbacks.entries()];
      callbacks.clear();
      for (const [, cb] of pending) cb(time);
    },
    pendingCount() {
      return callbacks.size;
    },
    uninstall() {
      delete globalThis.requestAnimationFrame;
      delete globalThis.cancelAnimationFrame;
    }
  };
}

function hasUnpairedSurrogate(input) {
  for (let i = 0; i < input.length; i++) {
    const code = input.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = input.charCodeAt(i + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return true;
      i++;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return true;
    }
  }
  return false;
}

{
  const raf = installRaf();
  const stream = createSmoothMarkdownStream({ startDelayMs: 80 });
  stream.enqueue("hello");
  const snap = stream.getSnapshot();
  assert.equal(snap.source, "hello");
  assert.notEqual(snap.visible, snap.source);
  stream.destroy();
  raf.uninstall();
}

{
  const raf = installRaf();
  const stream = createSmoothMarkdownStream();
  stream.enqueue("hello");
  stream.flush();
  const snap = stream.getSnapshot();
  assert.equal(snap.visible, snap.source);
  assert.equal(snap.caughtUp, true);
  stream.destroy();
  raf.uninstall();
}

{
  const stream = createSmoothMarkdownStream();
  stream.enqueue("hello");
  stream.finish({ flush: true });
  const snap = stream.getSnapshot();
  assert.equal(snap.visible, snap.source);
  assert.equal(snap.final, true);
}

{
  const raf = installRaf();
  const stream = createSmoothMarkdownStream({ startDelayMs: 0, minCharsPerSecond: 1000, maxCharsPerSecond: 1000 });
  stream.enqueue("hello");
  stream.finish();
  let snap = stream.getSnapshot();
  assert.equal(snap.done, true);
  assert.equal(snap.final, false);
  for (let t = 40; t < 1000 && !stream.getSnapshot().final; t += 40) raf.step(t);
  snap = stream.getSnapshot();
  assert.equal(snap.visible, snap.source);
  assert.equal(snap.final, true);
  stream.destroy();
  raf.uninstall();
}

{
  const raf = installRaf();
  const stream = createSmoothMarkdownStream({ startDelayMs: 0, minCharsPerSecond: 1000, maxCharsPerSecond: 1000, maxCharsPerCommit: 1 });
  stream.enqueue("hello 👨‍💻 world 🙂🙂");
  for (let t = 40; t < 2000 && !stream.getSnapshot().caughtUp; t += 40) {
    raf.step(t);
    assert.equal(hasUnpairedSurrogate(stream.getSnapshot().visible), false);
  }
  assert.equal(stream.getSnapshot().visible, stream.getSnapshot().source);
  stream.destroy();
  raf.uninstall();
}

{
  const raf = installRaf();
  const commits = [];
  const stream = createSmoothMarkdownStream({ startDelayMs: 0, minCharsPerSecond: 1000, maxCharsPerSecond: 1000, maxCharsPerCommit: 3 }, () => {
    commits.push(stream.getSnapshot().visible.length);
  });
  stream.enqueue("abcdefghijklmnop");
  const before = stream.getSnapshot().visible.length;
  raf.step(100);
  const after = stream.getSnapshot().visible.length;
  assert.ok(after - before <= 3);
  stream.destroy();
  raf.uninstall();
}

{
  const raf = installRaf();
  const stream = createSmoothMarkdownStream();
  stream.enqueue("hello");
  stream.pause();
  assert.equal(stream.getSnapshot().paused, true);
  const visible = stream.getSnapshot().visible;
  raf.step(1000);
  assert.equal(stream.getSnapshot().visible, visible);
  stream.resume();
  assert.equal(stream.getSnapshot().paused, false);
  stream.destroy();
  assert.doesNotThrow(() => raf.step(2000));
  assert.equal(raf.pendingCount(), 0);
  raf.uninstall();
}

{
  const stream = createSmoothMarkdownStream();
  stream.enqueue("fallback");
  assert.equal(stream.getSnapshot().visible, "fallback");
  assert.equal(stream.getSnapshot().caughtUp, true);
}

console.log("smooth_stream_controller_test passed");
