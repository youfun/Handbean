import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import {
  ComposerSpeech,
  downsampleTo16Khz,
  encodeFloat32LittleEndian,
  limitRecordingDuration,
  mergeFloat32Chunks,
  mixToMono,
} from "../js/hooks/composer_speech.js";

{
  const source = new Float32Array(48_000).fill(0.25);
  const output = downsampleTo16Khz(source, 48_000);
  assert.equal(output.length, 16_000);
  assert.ok(output.every((sample) => Math.abs(sample - 0.25) < 0.000001));
}

{
  const source = new Float32Array(8_000).fill(-0.5);
  const output = downsampleTo16Khz(source, 8_000);
  assert.equal(output.length, 16_000);
  assert.ok(output.every((sample) => Math.abs(sample + 0.5) < 0.000001));
}

{
  const source = new Float32Array(16_000 * 61);
  assert.equal(limitRecordingDuration(source).length, 16_000 * 60);
}

{
  const merged = mergeFloat32Chunks([
    new Float32Array([0.1, 0.2]),
    new Float32Array([0.3]),
  ]);
  assert.equal(merged.length, 3);
  assert.ok(Math.abs(merged[0] - 0.1) < 0.000001);
  assert.ok(Math.abs(merged[1] - 0.2) < 0.000001);
  assert.ok(Math.abs(merged[2] - 0.3) < 0.000001);
}

{
  const encoded = encodeFloat32LittleEndian(new Float32Array([-2, 0.5, 2]));
  const view = new DataView(encoded);
  assert.equal(view.getFloat32(0, true), -1);
  assert.equal(view.getFloat32(4, true), 0.5);
  assert.equal(view.getFloat32(8, true), 1);
}

{
  const channels = [new Float32Array([1, 0]), new Float32Array([-1, 1])];
  const mono = mixToMono({
    length: 2,
    numberOfChannels: channels.length,
    getChannelData: (channel) => channels[channel],
  });

  assert.deepEqual(Array.from(mono), [0, 0.5]);
}

{
  const dom = new JSDOM(`
    <!doctype html>
    <div
      id="composer-speech"
      data-speech-upload-name="speech_audio"
      data-label-start="Start voice input"
      data-label-stop="Stop recording"
      data-label-processing="Transcribing voice"
    >
      <textarea id="ai-input"></textarea>
      <button id="speech-input-button" type="button"><span>mic</span></button>
    </div>
  `);

  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  const navigatorDescriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", { value: {}, configurable: true });

  const callbacks = new Map();
  const errors = [];
  const hook = {
    ...ComposerSpeech,
    el: document.querySelector("#composer-speech"),
    handleEvent: (name, callback) => callbacks.set(name, callback),
    pushEvent: (name, payload) => errors.push({ name, payload }),
    upload: () => {},
  };

  hook.mounted();
  callbacks.get("speech-transcription")({ value: "你好 Handbean" });
  assert.equal(document.querySelector("#ai-input").value, "你好 Handbean");

  document.querySelector("#speech-input-button").click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(errors, [{ name: "speech_error", payload: { reason: "unsupported" } }]);
  assert.equal(document.querySelector("#speech-input-button").getAttribute("aria-pressed"), "false");

  hook.setState("recording");
  hook.el.querySelector("#speech-input-button").dataset.state = "ready";
  hook.updated();
  assert.equal(hook.el.querySelector("#speech-input-button").dataset.state, "recording");
  assert.equal(document.querySelector("#speech-input-button").title, "Stop recording");
  assert.equal(document.querySelector("#speech-input-button").getAttribute("aria-pressed"), "true");

  hook.destroyed();
  delete globalThis.window;
  delete globalThis.document;
  if (navigatorDescriptor) {
    Object.defineProperty(globalThis, "navigator", navigatorDescriptor);
  } else {
    delete globalThis.navigator;
  }
}

{
  const dom = new JSDOM(`
    <!doctype html>
    <div id="pcm-speech" data-speech-upload-name="speech_audio">
      <textarea id="ai-input"></textarea>
      <button id="speech-input-button" type="button"></button>
    </div>
  `);

  const navigatorDescriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  const mediaRecorderDescriptor = Object.getOwnPropertyDescriptor(globalThis, "MediaRecorder");
  const uploads = [];
  let trackStopped = false;

  class FakeAudioNode {
    constructor() {
      this.channelCount = 1;
      this.gain = { value: 1 };
      this.onaudioprocess = null;
    }
    connect() {}
    disconnect() {}
  }

  class FakeAudioContext {
    constructor() {
      this.sampleRate = 16_000;
      this.destination = new FakeAudioNode();
    }
    async resume() {}
    createMediaStreamSource() { return new FakeAudioNode(); }
    createScriptProcessor() { return new FakeAudioNode(); }
    createGain() { return new FakeAudioNode(); }
    close() { return Promise.resolve(); }
  }

  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  window.AudioContext = FakeAudioContext;
  Object.defineProperty(globalThis, "MediaRecorder", { value: undefined, configurable: true });
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      mediaDevices: {
        getUserMedia: async () => ({
          getTracks: () => [{ stop: () => { trackStopped = true; } }],
        }),
      },
    },
  });

  const hook = {
    ...ComposerSpeech,
    el: document.querySelector("#pcm-speech"),
    handleEvent: () => {},
    pushEvent: () => {},
    upload: (_name, files) => uploads.push(...files),
  };

  hook.mounted();
  await hook.startRecording();
  assert.equal(hook.pcmRecording, true);
  hook.captureProcessor.onaudioprocess({
    inputBuffer: {
      length: 2,
      numberOfChannels: 1,
      getChannelData: () => new Float32Array([0.25, -0.25]),
    },
  });
  hook.stopRecording();

  assert.equal(uploads.length, 1);
  assert.equal(uploads[0].size, 8);
  assert.equal(trackStopped, true);
  hook.destroyed();

  delete globalThis.window;
  delete globalThis.document;
  if (navigatorDescriptor) {
    Object.defineProperty(globalThis, "navigator", navigatorDescriptor);
  } else {
    delete globalThis.navigator;
  }
  if (mediaRecorderDescriptor) {
    Object.defineProperty(globalThis, "MediaRecorder", mediaRecorderDescriptor);
  } else {
    delete globalThis.MediaRecorder;
  }
}

console.log("composer_speech_test passed");
