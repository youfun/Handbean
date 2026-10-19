const TARGET_SAMPLE_RATE = 16_000;
const MAX_RECORDING_MS = 60_000;
const MAX_SAMPLES = TARGET_SAMPLE_RATE * MAX_RECORDING_MS / 1_000;

export function downsampleTo16Khz(samples, sourceRate) {
  if (!(samples instanceof Float32Array) || !Number.isFinite(sourceRate) || sourceRate <= 0) {
    throw new TypeError("invalid audio samples");
  }

  if (samples.length === 0) return new Float32Array();
  if (sourceRate === TARGET_SAMPLE_RATE) return new Float32Array(samples);

  const outputLength = Math.max(1, Math.floor(samples.length * TARGET_SAMPLE_RATE / sourceRate));
  const output = new Float32Array(outputLength);
  const ratio = sourceRate / TARGET_SAMPLE_RATE;

  if (ratio < 1) {
    for (let index = 0; index < outputLength; index += 1) {
      const position = Math.min(samples.length - 1, index * ratio);
      const left = Math.floor(position);
      const right = Math.min(samples.length - 1, left + 1);
      const fraction = position - left;
      output[index] = samples[left] * (1 - fraction) + samples[right] * fraction;
    }

    return output;
  }

  for (let index = 0; index < outputLength; index += 1) {
    const start = index * ratio;
    const end = Math.min(samples.length, (index + 1) * ratio);
    const first = Math.floor(start);
    const last = Math.max(first + 1, Math.ceil(end));
    let weighted = 0;
    let weight = 0;

    for (let sourceIndex = first; sourceIndex < last; sourceIndex += 1) {
      const overlap = Math.max(0, Math.min(end, sourceIndex + 1) - Math.max(start, sourceIndex));
      weighted += (samples[sourceIndex] || 0) * overlap;
      weight += overlap;
    }

    output[index] = weight > 0 ? weighted / weight : 0;
  }

  return output;
}

export function limitRecordingDuration(samples) {
  return samples.length > MAX_SAMPLES ? samples.subarray(0, MAX_SAMPLES) : samples;
}

export function mergeFloat32Chunks(chunks) {
  const length = chunks.reduce((total, chunk) => total + chunk.length, 0);
  const merged = new Float32Array(length);
  let offset = 0;

  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.length;
  }

  return merged;
}

export function encodeFloat32LittleEndian(samples) {
  const buffer = new ArrayBuffer(samples.length * Float32Array.BYTES_PER_ELEMENT);
  const view = new DataView(buffer);

  for (let index = 0; index < samples.length; index += 1) {
    const sample = Math.max(-1, Math.min(1, samples[index] || 0));
    view.setFloat32(index * Float32Array.BYTES_PER_ELEMENT, sample, true);
  }

  return buffer;
}

export function mixToMono(audioBuffer) {
  const mono = new Float32Array(audioBuffer.length);

  for (let channel = 0; channel < audioBuffer.numberOfChannels; channel += 1) {
    const input = audioBuffer.getChannelData(channel);
    for (let index = 0; index < input.length; index += 1) {
      mono[index] += input[index] / audioBuffer.numberOfChannels;
    }
  }

  return mono;
}

function recorderOptions() {
  if (typeof MediaRecorder === "undefined" || typeof MediaRecorder.isTypeSupported !== "function") {
    return undefined;
  }

  for (const mimeType of ["audio/webm;codecs=opus", "audio/mp4", "audio/webm"]) {
    if (MediaRecorder.isTypeSupported(mimeType)) return { mimeType };
  }

  return undefined;
}

function errorReason(error) {
  switch (error?.name) {
    case "NotAllowedError": return "permission_denied";
    case "NotFoundError": return "microphone_missing";
    case "NotReadableError": return "microphone_busy";
    default: return "capture_failed";
  }
}

function audioContextClass() {
  return window.AudioContext || window.webkitAudioContext;
}

export const ComposerSpeech = {
  mounted() {
    this.textarea = this.el.querySelector("#ai-input");
    this.uploadName = this.el.dataset.speechUploadName;
    this.mediaRecorder = null;
    this.stream = null;
    this.chunks = [];
    this.pcmChunks = [];
    this.pcmRecording = false;
    this.captureContext = null;
    this.captureSource = null;
    this.captureProcessor = null;
    this.captureGain = null;
    this.captureSampleRate = TARGET_SAMPLE_RATE;
    this.discardRecording = false;
    this.localState = this.el.dataset.speechState || "idle";
    this.maxTimer = null;

    this.onClick = (event) => {
      const button = event.target.closest("#speech-input-button");
      if (!button || !this.el.contains(button) || button.disabled) return;

      if (this.isRecording()) {
        this.stopRecording();
      } else {
        this.startRecording();
      }
    };

    this.onKeyDown = (event) => {
      if (event.key === "Escape" && this.isRecording()) {
        event.preventDefault();
        this.stopRecording();
      }
    };

    this.handleEvent?.("speech-transcription", ({ value }) => {
      if (!this.textarea) return;
      this.textarea.value = String(value || "");
      this.textarea.focus();
      this.textarea.setSelectionRange?.(this.textarea.value.length, this.textarea.value.length);
      this.setState("idle");
    });

    this.handleEvent?.("speech-transcription-failed", () => this.setState("idle"));
    this.handleEvent?.("speech-cancel", () => this.cancelRecording());

    this.el.addEventListener("click", this.onClick);
    window.addEventListener("keydown", this.onKeyDown);
  },

  updated() {
    this.textarea = this.el.querySelector("#ai-input");

    if (this.localState === "recording" || this.localState === "processing") {
      this.setState(this.localState);
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
    window.removeEventListener("keydown", this.onKeyDown);
    this.cancelRecording();
  },

  isRecording() {
    return this.mediaRecorder?.state === "recording" || this.pcmRecording;
  },

  async startRecording() {
    const AudioContextClass = audioContextClass();
    if (!navigator.mediaDevices?.getUserMedia || (!AudioContextClass && typeof MediaRecorder === "undefined")) {
      this.reportError("unsupported");
      return;
    }

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
        },
      });

      this.chunks = [];
      this.pcmChunks = [];
      this.discardRecording = false;

      if (typeof MediaRecorder !== "undefined") {
        try {
          this.startMediaRecorder();
        } catch (error) {
          if (!AudioContextClass) throw error;
          this.mediaRecorder = null;
          await this.startPcmRecorder(AudioContextClass);
        }
      } else {
        await this.startPcmRecorder(AudioContextClass);
      }

      this.setState("recording");
      this.maxTimer = window.setTimeout(() => this.stopRecording(), MAX_RECORDING_MS);
    } catch (error) {
      this.cleanupPcmGraph();
      this.stopTracks();
      this.reportError(errorReason(error));
    }
  },

  startMediaRecorder() {
    const options = recorderOptions();
    this.mediaRecorder = options
      ? new MediaRecorder(this.stream, options)
      : new MediaRecorder(this.stream);
    this.mediaRecorder.addEventListener("dataavailable", (event) => {
      if (event.data?.size > 0) this.chunks.push(event.data);
    });
    this.mediaRecorder.addEventListener("stop", () => this.processMediaRecording());
    this.mediaRecorder.start();
  },

  async startPcmRecorder(AudioContextClass) {
    if (!AudioContextClass) throw new Error("AudioContext is unavailable");

    this.captureContext = new AudioContextClass();
    await this.captureContext.resume?.();
    this.captureSampleRate = this.captureContext.sampleRate;
    this.captureSource = this.captureContext.createMediaStreamSource(this.stream);

    if (typeof this.captureContext.createScriptProcessor !== "function") {
      throw new Error("PCM capture is unavailable");
    }

    const inputChannels = Math.max(1, Math.min(2, this.captureSource.channelCount || 1));
    this.captureProcessor = this.captureContext.createScriptProcessor(4096, inputChannels, 1);
    this.captureGain = this.captureContext.createGain();
    this.captureGain.gain.value = 0;
    this.captureProcessor.onaudioprocess = (event) => {
      if (this.pcmRecording) this.pcmChunks.push(mixToMono(event.inputBuffer));
    };
    this.captureSource.connect(this.captureProcessor);
    this.captureProcessor.connect(this.captureGain);
    this.captureGain.connect(this.captureContext.destination);
    this.pcmRecording = true;
  },

  stopRecording() {
    if (!this.isRecording()) return;
    this.cancelTimer();
    this.setState("processing");

    if (this.mediaRecorder?.state === "recording") {
      this.mediaRecorder.stop();
      return;
    }

    const chunks = this.pcmChunks;
    const sampleRate = this.captureSampleRate;
    this.pcmRecording = false;
    this.cleanupPcmGraph();
    this.stopTracks();
    this.processPcmRecording(chunks, sampleRate);
  },

  cancelRecording() {
    this.discardRecording = true;
    this.cancelTimer();

    if (this.mediaRecorder?.state === "recording") {
      this.mediaRecorder.stop();
    } else {
      this.pcmRecording = false;
      this.cleanupPcmGraph();
      this.stopTracks();
      this.resetCapture();
    }

    this.setState("idle");
  },

  async processMediaRecording() {
    this.stopTracks();

    if (this.discardRecording) {
      this.discardRecording = false;
      this.resetCapture();
      return;
    }

    if (this.chunks.length === 0) {
      this.resetCapture();
      this.reportError("empty_recording");
      return;
    }

    let context;

    try {
      const blob = new Blob(this.chunks, { type: this.mediaRecorder?.mimeType || "audio/webm" });
      const AudioContextClass = audioContextClass();
      if (!AudioContextClass) throw new Error("AudioContext is unavailable");

      context = new AudioContextClass();
      const decoded = await context.decodeAudioData(await blob.arrayBuffer());
      this.uploadSamples(mixToMono(decoded), decoded.sampleRate);
    } catch (_error) {
      this.reportError("decode_failed");
    } finally {
      await context?.close?.();
      this.resetCapture();
    }
  },

  processPcmRecording(chunks, sampleRate) {
    if (this.discardRecording) {
      this.discardRecording = false;
      this.resetCapture();
      return;
    }

    const samples = mergeFloat32Chunks(chunks);
    if (samples.length === 0) {
      this.resetCapture();
      this.reportError("empty_recording");
      return;
    }

    this.uploadSamples(samples, sampleRate);
    this.resetCapture();
  },

  uploadSamples(samples, sampleRate) {
    const normalized = limitRecordingDuration(downsampleTo16Khz(samples, sampleRate));
    const pcm = encodeFloat32LittleEndian(normalized);
    const file = new File([pcm], `dictation-${Date.now()}.pcm`, {
      type: "application/octet-stream",
    });

    this.upload(this.uploadName, [file]);
  },

  cleanupPcmGraph() {
    if (this.captureProcessor) this.captureProcessor.onaudioprocess = null;
    for (const node of [this.captureSource, this.captureProcessor, this.captureGain]) {
      try { node?.disconnect?.(); } catch (_error) {}
    }
    this.captureContext?.close?.().catch?.(() => {});
    this.captureContext = null;
    this.captureSource = null;
    this.captureProcessor = null;
    this.captureGain = null;
  },

  resetCapture() {
    this.mediaRecorder = null;
    this.chunks = [];
    this.pcmChunks = [];
    this.pcmRecording = false;
  },

  stopTracks() {
    for (const track of this.stream?.getTracks?.() || []) track.stop();
    this.stream = null;
  },

  cancelTimer() {
    if (this.maxTimer) window.clearTimeout(this.maxTimer);
    this.maxTimer = null;
  },

  setState(state) {
    this.localState = state;
    this.el.dataset.speechState = state;
    const button = this.el.querySelector("#speech-input-button");
    if (!button) return;

    button.dataset.state = state;
    button.setAttribute("aria-pressed", state === "recording" ? "true" : "false");
    button.disabled = state === "processing";

    const label = state === "recording"
      ? this.el.dataset.labelStop
      : state === "processing"
        ? this.el.dataset.labelProcessing
        : this.el.dataset.labelStart;

    if (label) {
      button.setAttribute("aria-label", label);
      button.title = label;
    }
  },

  reportError(reason) {
    this.setState("idle");
    this.pushEvent?.("speech_error", { reason });
  },
};

export default ComposerSpeech;
