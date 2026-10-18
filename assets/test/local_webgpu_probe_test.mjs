import assert from "node:assert/strict";
import { runLocalWebGPUProbe } from "../js/hooks/local_webgpu_probe.js";

function baseEnvironment(overrides = {}) {
  return {
    navigator: { userAgent: "test-browser" },
    isSecureContext: true,
    setTimeout,
    clearTimeout,
    crypto: { randomUUID: () => "probe-id" },
    ...overrides,
  };
}

function readySharedWorker() {
  return class {
    constructor() {
      this.port = {
        addEventListener: (_name, listener) => queueMicrotask(() => listener({ data: "ready" })),
        start: () => {},
        close: () => {},
      };
    }
  };
}

function readyOPFS() {
  let contents = "";
  const root = {
    getFileHandle: async () => ({
      createWritable: async () => ({
        write: async (value) => { contents = value; },
        close: async () => {},
      }),
      getFile: async () => ({ text: async () => contents }),
    }),
    removeEntry: async () => {},
  };
  return { getDirectory: async () => root };
}

function readyWebGPU() {
  const readback = {
    mapAsync: async () => {},
    getMappedRange: () => new Float32Array([5, 5, 5, 5]).buffer,
    unmap: () => {},
    destroy: () => {},
  };
  const genericBuffer = { destroy: () => {} };
  let bufferCount = 0;
  const device = {
    createBuffer: () => (++bufferCount === 4 ? readback : genericBuffer),
    queue: { writeBuffer: () => {}, submit: () => {} },
    createShaderModule: () => ({}),
    createComputePipeline: () => ({ getBindGroupLayout: () => ({}) }),
    createBindGroup: () => ({}),
    createCommandEncoder: () => ({
      beginComputePass: () => ({
        setPipeline: () => {},
        setBindGroup: () => {},
        dispatchWorkgroups: () => {},
        end: () => {},
      }),
      copyBufferToBuffer: () => {},
      finish: () => ({}),
    }),
    destroy: () => {},
  };
  return { requestAdapter: async () => ({ requestDevice: async () => device }) };
}

{
  const probe = await runLocalWebGPUProbe(baseEnvironment());
  assert.equal(probe.status, "unsupported");
  assert.equal(probe.checks.navigator_gpu.status, "unsupported");
  assert.equal(probe.checks.shared_worker.status, "unsupported");
  assert.equal(probe.checks.opfs.status, "unsupported");
}

{
  const environment = baseEnvironment({
    navigator: {
      userAgent: "test-browser",
      gpu: readyWebGPU(),
      storage: readyOPFS(),
    },
    SharedWorker: readySharedWorker(),
    GPUBufferUsage: { STORAGE: 1, COPY_DST: 2, COPY_SRC: 4, MAP_READ: 8 },
    GPUMapMode: { READ: 1 },
  });
  const probe = await runLocalWebGPUProbe(environment);
  assert.equal(probe.status, "ready");
  assert.deepEqual(
    Object.values(probe.checks).map(({ status }) => status),
    ["ready", "ready", "ready", "ready", "ready", "ready"],
  );
  assert.match(probe.checks.compute.detail, /\[5, 5, 5, 5\]/);
}

{
  const environment = baseEnvironment({
    navigator: {
      userAgent: "test-browser",
      gpu: { requestAdapter: async () => { throw new Error("adapter blocked"); } },
      storage: readyOPFS(),
    },
    SharedWorker: readySharedWorker(),
  });
  const probe = await runLocalWebGPUProbe(environment);
  assert.equal(probe.status, "probe_failure");
  assert.equal(probe.checks.adapter.status, "probe_failure");
  assert.equal(probe.checks.adapter.detail, "adapter blocked");
  assert.equal(probe.checks.device.status, "unsupported");
}

{
  const environment = baseEnvironment({
    navigator: {
      userAgent: "test-browser",
      gpu: { requestAdapter: async () => null },
      storage: readyOPFS(),
    },
    SharedWorker: readySharedWorker(),
  });
  const probe = await runLocalWebGPUProbe(environment);
  assert.equal(probe.status, "unsupported");
  assert.equal(probe.checks.adapter.status, "unsupported");
  assert.match(probe.checks.adapter.detail, /no adapter/);
}

{
  const environment = baseEnvironment({
    navigator: {
      userAgent: "test-browser",
      gpu: { requestAdapter: () => new Promise(() => {}) },
      storage: readyOPFS(),
    },
    SharedWorker: readySharedWorker(),
  });
  const probe = await runLocalWebGPUProbe(environment, { timeoutMs: 1 });
  assert.equal(probe.status, "probe_failure");
  assert.equal(probe.checks.adapter.status, "probe_failure");
  assert.equal(probe.checks.adapter.detail, "requestAdapter timed out");
}

{
  const environment = baseEnvironment({
    navigator: {
      userAgent: "test-browser",
      gpu: readyWebGPU(),
      storage: { getDirectory: async () => { throw new Error("OPFS denied"); } },
    },
    SharedWorker: readySharedWorker(),
    GPUBufferUsage: { STORAGE: 1, COPY_DST: 2, COPY_SRC: 4, MAP_READ: 8 },
    GPUMapMode: { READ: 1 },
  });
  const probe = await runLocalWebGPUProbe(environment);
  assert.equal(probe.status, "probe_failure");
  assert.equal(probe.checks.opfs.status, "probe_failure");
  assert.equal(probe.checks.opfs.detail, "OPFS denied");
}

{
  const environment = baseEnvironment({
    navigator: {
      userAgent: "test-browser",
      gpu: readyWebGPU(),
      storage: { getDirectory: () => new Promise(() => {}) },
    },
    SharedWorker: readySharedWorker(),
    GPUBufferUsage: { STORAGE: 1, COPY_DST: 2, COPY_SRC: 4, MAP_READ: 8 },
    GPUMapMode: { READ: 1 },
  });
  const probe = await runLocalWebGPUProbe(environment, { timeoutMs: 1 });
  assert.equal(probe.status, "probe_failure");
  assert.equal(probe.checks.opfs.status, "probe_failure");
  assert.equal(probe.checks.opfs.detail, "OPFS probe timed out");
}

console.log("local_webgpu_probe_test passed");
