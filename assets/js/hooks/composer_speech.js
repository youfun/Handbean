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

/**
 * Map a smoothed level (0..1) onto one dot of the activity line. Dots nearer
 * the middle of the line react more, so speech reads as a waveform instead of a
 * single uniform pulse.
 */
export function activityDotScale(level, index, count) {
  const position = count > 1 ? index / (count - 1) : 0.5;
  const shape = Math.sin(Math.PI * Math.min(1, Math.max(0, position)));
  return 1 + Math.min(1, Math.max(0, level)) * (1.2 + 4.8 * shape);
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
    this.captureAnalyser = null;
    this.captureProcessor = null;
    this.captureGain = null;
    this.captureSampleRate = TARGET_SAMPLE_RATE;
    this.captureRevision = 0;
    this.starting = false;
    this.finishing = false;
    this.levelFrame = null;
    this.level = 0;
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

    if (this.localState === "recording" && this.captureAnalyser) {
      this.stopLevelLoop();
      this.startLevelLoop();
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
    if (this.starting || this.finishing || this.isRecording()) return;

    const AudioContextClass = audioContextClass();
    if (!navigator.mediaDevices?.getUserMedia || (!AudioContextClass && typeof MediaRecorder === "undefined")) {
      this.reportError("unsupported");
      return;
    }

    const revision = ++this.captureRevision;
    let pendingStream = null;
    this.starting = true;

    try {
      pendingStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
        },
      });

      if (revision !== this.captureRevision) {
        this.stopStream(pendingStream);
        return;
      }

      this.stream = pendingStream;
      pendingStream = null;
      this.chunks = [];
      this.pcmChunks = [];
      this.discardRecording = false;

      if (typeof MediaRecorder !== "undefined") {
        try {
          this.startMediaRecorder(revision);
        } catch (error) {
          this.mediaRecorder = null;
          if (!AudioContextClass) throw error;

          await this.prepareCaptureGraph(AudioContextClass);
          if (revision !== this.captureRevision) return;
          this.startPcmCapture();
        }

        if (this.mediaRecorder && AudioContextClass) {
          try {
            const resume = this.prepareCaptureGraph(AudioContextClass);
            Promise.resolve(resume).catch(() => {
              if (revision !== this.captureRevision) return;
              this.stopLevelLoop();
              this.cleanupCaptureGraph();
              this.syncActivity(this.localState);
            });
          } catch (_error) {
            this.cleanupCaptureGraph();
          }
        }
      } else {
        await this.prepareCaptureGraph(AudioContextClass);
        if (revision !== this.captureRevision) return;
        this.startPcmCapture();
      }

      this.setState("recording");
      this.startLevelLoop();
      this.maxTimer = window.setTimeout(() => this.stopRecording(), MAX_RECORDING_MS);
    } catch (error) {
      this.stopStream(pendingStream);
      if (revision !== this.captureRevision) return;

      this.cleanupCaptureGraph();
      this.stopTracks();
      this.reportError(errorReason(error));
    } finally {
      if (revision === this.captureRevision) this.starting = false;
    }
  },

  prepareCaptureGraph(AudioContextClass) {
    this.captureContext = new AudioContextClass();
    this.captureSampleRate = this.captureContext.sampleRate;
    this.captureSource = this.captureContext.createMediaStreamSource(this.stream);
    this.prepareActivityAnalyser();
    return this.captureContext.resume?.();
  },

  prepareActivityAnalyser() {
    if (typeof this.captureContext?.createAnalyser !== "function") return;

    try {
      this.captureAnalyser = this.captureContext.createAnalyser();
      this.captureAnalyser.fftSize = 1024;
      this.captureAnalyser.smoothingTimeConstant = 0.7;
      this.captureGain = this.captureContext.createGain();
      this.captureGain.gain.value = 0;
      this.captureSource.connect(this.captureAnalyser);
      this.captureAnalyser.connect(this.captureGain);
      this.captureGain.connect(this.captureContext.destination);
    } catch (_error) {
      for (const node of [this.captureSource, this.captureAnalyser, this.captureGain]) {
        try { node?.disconnect?.(); } catch (_disconnectError) {}
      }

      this.captureAnalyser = null;
      this.captureGain = null;
    }
  },

  startMediaRecorder(revision) {
    const options = recorderOptions();
    const recorder = options
      ? new MediaRecorder(this.stream, options)
      : new MediaRecorder(this.stream);

    this.mediaRecorder = recorder;
    recorder.addEventListener("dataavailable", (event) => {
      if (event.data?.size > 0 && revision === this.captureRevision) {
        this.chunks.push(event.data);
      }
    });
    recorder.addEventListener("stop", () => this.processMediaRecording(revision, recorder));
    recorder.start();
  },

  startPcmCapture() {
    if (!this.captureContext || !this.captureSource) {
      throw new Error("AudioContext is unavailable");
    }

    if (typeof this.captureContext.createScriptProcessor !== "function") {
      throw new Error("PCM capture is unavailable");
    }

    const inputChannels = Math.max(1, Math.min(2, this.captureSource.channelCount || 1));
    this.captureProcessor = this.captureContext.createScriptProcessor(4096, inputChannels, 1);
    this.captureProcessor.onaudioprocess = (event) => {
      if (this.pcmRecording) this.pcmChunks.push(mixToMono(event.inputBuffer));
    };
    this.captureSource.connect(this.captureProcessor);
    this.captureProcessor.connect(this.captureContext.destination);
    this.pcmRecording = true;
  },

  startLevelLoop() {
    if (!this.captureAnalyser || window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) {
      return;
    }

    const dots = this.activityDots();
    if (dots.length === 0) return;

    const buffer = new Uint8Array(this.captureAnalyser.fftSize);
    const analyser = this.captureAnalyser;

    const tick = () => {
      analyser.getByteTimeDomainData(buffer);
      let sum = 0;

      for (let index = 0; index < buffer.length; index += 1) {
        const sample = (buffer[index] - 128) / 128;
        sum += sample * sample;
      }

      const rms = Math.sqrt(sum / buffer.length);
      this.level = this.level * 0.6 + Math.min(1, rms * 6) * 0.4;
      this.renderLevel(dots, this.level);

      this.levelFrame = window.requestAnimationFrame(tick);
    };

    tick();
  },

  stopLevelLoop() {
    if (this.levelFrame !== null) window.cancelAnimationFrame(this.levelFrame);
    this.levelFrame = null;
    this.level = 0;
    this.resetActivityDots();
  },

  renderLevel(dots, level) {
    dots.forEach((dot, index) => {
      dot.style.transform = `scaleY(${activityDotScale(level, index, dots.length).toFixed(2)})`;
      dot.style.opacity = String(0.35 + Math.min(1, level) * 0.55);
    });
  },

  resetActivityDots() {
    for (const dot of this.activityDots()) {
      dot.style.transform = "";
      dot.style.opacity = "";
    }
  },

  activityElement() {
    const form = this.el.closest("form");
    return form?.querySelector("#composer-activity") ?? null;
  },

  activityDots() {
    const container = this.activityElement();
    return container ? Array.from(container.querySelectorAll(".composer-activity-dot")) : [];
  },

  stopRecording() {
    if (!this.isRecording()) return;
    this.cancelTimer();
    this.setState("processing");
    this.stopLevelLoop();

    if (this.mediaRecorder?.state === "recording") {
      this.finishing = true;
      this.mediaRecorder.stop();
      return;
    }

    const chunks = this.pcmChunks;
    const sampleRate = this.captureSampleRate;
    this.pcmRecording = false;
    this.cleanupCaptureGraph();
    this.stopTracks();
    this.processPcmRecording(chunks, sampleRate);
  },

  cancelRecording() {
    this.captureRevision += 1;
    this.starting = false;
    this.discardRecording = true;
    this.cancelTimer();
    this.stopLevelLoop();

    if (this.mediaRecorder?.state === "recording") {
      this.finishing = true;
      this.mediaRecorder.stop();
    } else {
      this.pcmRecording = false;
      this.cleanupCaptureGraph();
      this.stopTracks();
      this.resetCapture();
    }

    this.setState("idle");
  },

  async processMediaRecording(revision, recorder) {
    this.finishing = true;
    this.stopTracks();
    this.cleanupCaptureGraph();

    if (this.discardRecording || revision !== this.captureRevision) {
      this.discardRecording = false;
      this.resetCapture();
      this.finishing = false;
      return;
    }

    if (this.chunks.length === 0) {
      this.resetCapture();
      this.finishing = false;
      this.reportError("empty_recording");
      return;
    }

    let context;

    try {
      const blob = new Blob(this.chunks, { type: recorder?.mimeType || "audio/webm" });
      const AudioContextClass = audioContextClass();
      if (!AudioContextClass) throw new Error("AudioContext is unavailable");

      context = new AudioContextClass();
      const decoded = await context.decodeAudioData(await blob.arrayBuffer());
      if (revision === this.captureRevision) {
        this.uploadSamples(mixToMono(decoded), decoded.sampleRate);
      }
    } catch (_error) {
      if (revision === this.captureRevision) this.reportError("decode_failed");
    } finally {
      try { await context?.close?.(); } catch (_error) {}
      this.resetCapture();
      this.finishing = false;
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

  cleanupCaptureGraph() {
    if (this.captureProcessor) this.captureProcessor.onaudioprocess = null;

    for (const node of [this.captureSource, this.captureAnalyser, this.captureProcessor, this.captureGain]) {
      try { node?.disconnect?.(); } catch (_error) {}
    }

    this.captureContext?.close?.()?.catch?.(() => {});
    this.captureContext = null;
    this.captureSource = null;
    this.captureAnalyser = null;
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
    this.stopStream(this.stream);
    this.stream = null;
  },

  stopStream(stream) {
    for (const track of stream?.getTracks?.() || []) track.stop();
  },

  cancelTimer() {
    if (this.maxTimer) window.clearTimeout(this.maxTimer);
    this.maxTimer = null;
  },

  setState(state) {
    this.localState = state;
    this.el.dataset.speechState = state;
    this.syncActivity(state);
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

  syncActivity(state) {
    const container = this.activityElement();
    if (!container) return;

    if (state === "recording" || state === "processing") {
      container.dataset.clientActive = "true";
      container.classList.toggle(
        "is-listening",
        state === "recording" && this.captureAnalyser != null,
      );
    } else {
      delete container.dataset.clientActive;
      container.classList.remove("is-listening");
      this.resetActivityDots();
    }
  },

  reportError(reason) {
    this.setState("idle");
    this.pushEvent?.("speech_error", { reason });
  },
};

export default ComposerSpeech;
