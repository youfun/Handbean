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

export const ComposerSpeech = {
  mounted() {
    this.textarea = this.el.querySelector("#ai-input");
    this.uploadName = this.el.dataset.speechUploadName;
    this.mediaRecorder = null;
    this.stream = null;
    this.chunks = [];
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
    this.cancelTimer();
    this.cancelRecording();
  },

  isRecording() {
    return this.mediaRecorder?.state === "recording";
  },

  async startRecording() {
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
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
      this.discardRecording = false;
      this.mediaRecorder = new MediaRecorder(this.stream, recorderOptions());
      this.mediaRecorder.addEventListener("dataavailable", (event) => {
        if (event.data?.size > 0) this.chunks.push(event.data);
      });
      this.mediaRecorder.addEventListener("stop", () => this.processRecording());
      this.mediaRecorder.start();
      this.setState("recording");
      this.maxTimer = window.setTimeout(() => this.stopRecording(), MAX_RECORDING_MS);
    } catch (error) {
      this.stopTracks();
      this.reportError(errorReason(error));
    }
  },

  stopRecording() {
    if (!this.isRecording()) return;
    this.cancelTimer();
    this.setState("processing");
    this.mediaRecorder.stop();
  },

  cancelRecording() {
    this.discardRecording = true;
    this.cancelTimer();

    if (this.isRecording()) {
      this.mediaRecorder.stop();
    } else {
      this.stopTracks();
      this.mediaRecorder = null;
      this.chunks = [];
    }

    this.setState("idle");
  },

  async processRecording() {
    this.stopTracks();

    if (this.discardRecording) {
      this.discardRecording = false;
      this.chunks = [];
      this.mediaRecorder = null;
      return;
    }

    if (this.chunks.length === 0) {
      this.reportError("empty_recording");
      return;
    }

    let context;

    try {
      const blob = new Blob(this.chunks, { type: this.mediaRecorder?.mimeType || "audio/webm" });
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) throw new Error("AudioContext is unavailable");

      context = new AudioContextClass();
      const decoded = await context.decodeAudioData(await blob.arrayBuffer());
      const mono = mixToMono(decoded);
      const samples = limitRecordingDuration(downsampleTo16Khz(mono, decoded.sampleRate));
      const pcm = encodeFloat32LittleEndian(samples);
      const file = new File([pcm], `dictation-${Date.now()}.pcm`, {
        type: "application/octet-stream",
      });

      this.upload(this.uploadName, [file]);
    } catch (_error) {
      this.reportError("decode_failed");
    } finally {
      await context?.close?.();
      this.chunks = [];
      this.mediaRecorder = null;
    }
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
