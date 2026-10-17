const STATUS = {
  UNSUPPORTED: "unsupported",
  FAILURE: "probe_failure",
  READY: "ready",
};

const CHECKS = [
  ["navigator_gpu", "navigator.gpu"],
  ["adapter", "requestAdapter"],
  ["device", "requestDevice"],
  ["compute", "WebGPU compute"],
  ["shared_worker", "SharedWorker"],
  ["opfs", "OPFS"],
];

function result(status, detail) {
  return { status, detail };
}

function errorDetail(error) {
  if (error instanceof Error && error.message) return error.message;
  return String(error || "Unknown error");
}

function notReached(detail) {
  return result(STATUS.UNSUPPORTED, `Not reached: ${detail}`);
}

function withTimeout(promise, environment, timeoutMs, label) {
  return new Promise((resolve, reject) => {
    const timer = environment.setTimeout(
      () => reject(new Error(`${label} timed out`)),
      timeoutMs,
    );

    Promise.resolve(promise).then(
      (value) => {
        environment.clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        environment.clearTimeout(timer);
        reject(error);
      },
    );
  });
}

async function probeWebGPU(environment, timeoutMs) {
  const results = {};
  const gpu = environment.navigator?.gpu;

  if (!gpu) {
    results.navigator_gpu = result(STATUS.UNSUPPORTED, "navigator.gpu is not available");
    results.adapter = notReached("navigator.gpu is unavailable");
    results.device = notReached("navigator.gpu is unavailable");
    results.compute = notReached("navigator.gpu is unavailable");
    return results;
  }

  results.navigator_gpu = result(STATUS.READY, "navigator.gpu is available");

  if (typeof gpu.requestAdapter !== "function") {
    results.adapter = result(STATUS.UNSUPPORTED, "requestAdapter is not available");
    results.device = notReached("requestAdapter is unavailable");
    results.compute = notReached("requestAdapter is unavailable");
    return results;
  }

  let adapter;
  try {
    adapter = await withTimeout(gpu.requestAdapter(), environment, timeoutMs, "requestAdapter");
  } catch (error) {
    results.adapter = result(STATUS.FAILURE, errorDetail(error));
    results.device = notReached("requestAdapter failed");
    results.compute = notReached("requestAdapter failed");
    return results;
  }

  if (!adapter) {
    results.adapter = result(STATUS.UNSUPPORTED, "requestAdapter returned no adapter");
    results.device = notReached("no adapter was returned");
    results.compute = notReached("no adapter was returned");
    return results;
  }

  results.adapter = result(STATUS.READY, "WebGPU adapter acquired");

  if (typeof adapter.requestDevice !== "function") {
    results.device = result(STATUS.UNSUPPORTED, "requestDevice is not available");
    results.compute = notReached("requestDevice is unavailable");
    return results;
  }

  let device;
  try {
    device = await withTimeout(adapter.requestDevice(), environment, timeoutMs, "requestDevice");
    results.device = result(STATUS.READY, "WebGPU device acquired");
  } catch (error) {
    results.device = result(STATUS.FAILURE, errorDetail(error));
    results.compute = notReached("requestDevice failed");
    return results;
  }

  try {
    const output = await runCompute(device, environment, timeoutMs);
    results.compute = result(STATUS.READY, `Output verified: [${output.join(", ")}]`);
  } catch (error) {
    results.compute = result(STATUS.FAILURE, errorDetail(error));
  } finally {
    device.destroy?.();
  }

  return results;
}

async function runCompute(device, environment, timeoutMs) {
  const usage = environment.GPUBufferUsage;
  const mapMode = environment.GPUMapMode;
  if (!usage || !mapMode) throw new Error("WebGPU buffer constants are unavailable");

  const inputValues = new Float32Array([1, 2, 3, 4]);
  const addValues = new Float32Array([4, 3, 2, 1]);
  const byteLength = inputValues.byteLength;
  const buffers = [];

  try {
    const input = device.createBuffer({
      size: byteLength,
      usage: usage.STORAGE | usage.COPY_DST,
    });
    const add = device.createBuffer({
      size: byteLength,
      usage: usage.STORAGE | usage.COPY_DST,
    });
    const output = device.createBuffer({
      size: byteLength,
      usage: usage.STORAGE | usage.COPY_SRC,
    });
    const readback = device.createBuffer({
      size: byteLength,
      usage: usage.COPY_DST | usage.MAP_READ,
    });
    buffers.push(input, add, output, readback);

    device.queue.writeBuffer(input, 0, inputValues);
    device.queue.writeBuffer(add, 0, addValues);

    const shader = device.createShaderModule({
      code: `
        @group(0) @binding(0) var<storage, read> input: array<f32>;
        @group(0) @binding(1) var<storage, read> add: array<f32>;
        @group(0) @binding(2) var<storage, read_write> output: array<f32>;

        @compute @workgroup_size(4)
        fn main(@builtin(global_invocation_id) id: vec3<u32>) {
          output[id.x] = input[id.x] + add[id.x];
        }
      `,
    });
    const pipeline = device.createComputePipeline({
      layout: "auto",
      compute: { module: shader, entryPoint: "main" },
    });
    const bindGroup = device.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: input } },
        { binding: 1, resource: { buffer: add } },
        { binding: 2, resource: { buffer: output } },
      ],
    });
    const encoder = device.createCommandEncoder();
    const pass = encoder.beginComputePass();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.dispatchWorkgroups(1);
    pass.end();
    encoder.copyBufferToBuffer(output, 0, readback, 0, byteLength);
    device.queue.submit([encoder.finish()]);

    await withTimeout(readback.mapAsync(mapMode.READ), environment, timeoutMs, "Compute readback");
    const values = Array.from(new Float32Array(readback.getMappedRange().slice(0)));
    readback.unmap();

    if (values.length !== 4 || values.some((value) => value !== 5)) {
      throw new Error(`Compute output mismatch: [${values.join(", ")}]`);
    }

    return values;
  } finally {
    buffers.forEach((buffer) => buffer.destroy?.());
  }
}

function probeSharedWorker(environment, timeoutMs) {
  if (typeof environment.SharedWorker !== "function") {
    return Promise.resolve(result(STATUS.UNSUPPORTED, "SharedWorker is not available"));
  }

  return new Promise((resolve) => {
    let worker;
    let settled = false;

    const finish = (value) => {
      if (settled) return;
      settled = true;
      environment.clearTimeout(timer);
      worker?.port?.close?.();
      resolve(value);
    };

    const timer = environment.setTimeout(
      () => finish(result(STATUS.FAILURE, "SharedWorker handshake timed out")),
      timeoutMs,
    );

    try {
      worker = new environment.SharedWorker("/assets/js/webgpu_probe_worker.js", {
        name: "handbean-capability-probe",
      });
      worker.port.addEventListener("message", (event) => {
        if (event.data === "ready") finish(result(STATUS.READY, "Worker handshake completed"));
        else finish(result(STATUS.FAILURE, "SharedWorker returned an unexpected response"));
      }, { once: true });
      worker.addEventListener?.("error", (event) => {
        event.preventDefault?.();
        finish(result(STATUS.FAILURE, event.message || "SharedWorker failed to start"));
      }, { once: true });
      worker.port.start();
    } catch (error) {
      finish(result(STATUS.FAILURE, errorDetail(error)));
    }
  });
}

async function probeOPFS(environment, timeoutMs) {
  const getDirectory = environment.navigator?.storage?.getDirectory;
  if (typeof getDirectory !== "function") {
    return result(STATUS.UNSUPPORTED, "navigator.storage.getDirectory is not available");
  }

  const filename = `.handbean-webgpu-probe-${environment.crypto?.randomUUID?.() || Date.now()}`;
  let root;
  let created = false;

  try {
    await withTimeout((async () => {
      root = await getDirectory.call(environment.navigator.storage);
      const handle = await root.getFileHandle(filename, { create: true });
      created = true;
      const writable = await handle.createWritable();
      await writable.write("handbean-opfs-probe");
      await writable.close();
      const contents = await (await handle.getFile()).text();
      if (contents !== "handbean-opfs-probe") throw new Error("OPFS readback mismatch");
    })(), environment, timeoutMs, "OPFS probe");
    return result(STATUS.READY, "Temporary file write/read/delete completed");
  } catch (error) {
    return result(STATUS.FAILURE, errorDetail(error));
  } finally {
    if (created) {
      try {
        await withTimeout(root.removeEntry(filename), environment, timeoutMs, "OPFS cleanup");
      } catch (_) {}
    }
  }
}

export async function runLocalWebGPUProbe(environment = globalThis, options = {}) {
  const timeoutMs = options.timeoutMs ?? 3000;
  const [webgpu, sharedWorker, opfs] = await Promise.all([
    probeWebGPU(environment, timeoutMs),
    probeSharedWorker(environment, timeoutMs),
    probeOPFS(environment, timeoutMs),
  ]);
  const checks = { ...webgpu, shared_worker: sharedWorker, opfs };
  const statuses = Object.values(checks).map((check) => check.status);
  const status = statuses.includes(STATUS.FAILURE)
    ? STATUS.FAILURE
    : statuses.every((value) => value === STATUS.READY)
      ? STATUS.READY
      : STATUS.UNSUPPORTED;

  return {
    status,
    checks,
    user_agent: environment.navigator?.userAgent || "unknown",
    secure_context: environment.isSecureContext === true,
    timestamp: new Date().toISOString(),
  };
}

const STATUS_LABEL_KEYS = {
  running: "statusRunning",
  ready: "statusReady",
  unsupported: "statusUnsupported",
  probe_failure: "statusProbeFailure",
};

function statusLabel(element, status) {
  return element.dataset[STATUS_LABEL_KEYS[status]] || status;
}

function renderProbe(element, probe) {
  element.dataset.probeStatus = probe.status;
  element.querySelector("[data-probe-summary]").textContent = statusLabel(element, probe.status);
  element.querySelector("[data-probe-meta]").textContent =
    `${probe.secure_context ? element.dataset.secureContext : element.dataset.insecureContext} · ${probe.user_agent}`;

  for (const [key, label] of CHECKS) {
    const check = probe.checks[key];
    const row = element.querySelector(`[data-probe-check="${key}"]`);
    row.dataset.status = check.status;
    row.querySelector("[data-check-label]").textContent = label;
    row.querySelector("[data-check-status]").textContent = statusLabel(element, check.status);
    row.querySelector("[data-check-detail]").textContent = check.detail;
  }

  element.querySelector("[data-probe-json]").textContent = JSON.stringify(probe, null, 2);
}

export const LocalWebGPUProbe = {
  mounted() {
    this.run = async () => {
      const button = this.el.querySelector("[data-probe-run]");
      button.disabled = true;
      button.textContent = this.el.dataset.runRunning || "Running…";
      this.el.dataset.probeStatus = "running";
      this.el.querySelector("[data-probe-summary]").textContent = statusLabel(this.el, "running");

      try {
        const probe = await runLocalWebGPUProbe(window);
        renderProbe(this.el, probe);
        window.dispatchEvent(new CustomEvent("handbean:webgpu-probe", { detail: probe }));
      } catch (error) {
        const probe = {
          status: STATUS.FAILURE,
          checks: Object.fromEntries(CHECKS.map(([key]) => [key, result(STATUS.FAILURE, errorDetail(error))])),
          user_agent: window.navigator?.userAgent || "unknown",
          secure_context: window.isSecureContext === true,
          timestamp: new Date().toISOString(),
        };
        renderProbe(this.el, probe);
        window.dispatchEvent(new CustomEvent("handbean:webgpu-probe", { detail: probe }));
      } finally {
        button.disabled = false;
        button.textContent = this.el.dataset.runAgain || "Run probe again";
      }
    };

    this.el.querySelector("[data-probe-run]").addEventListener("click", this.run);
    this.run();
  },

  destroyed() {
    this.el.querySelector("[data-probe-run]")?.removeEventListener("click", this.run);
  },
};
