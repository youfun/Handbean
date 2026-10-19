import { PeleError, render } from "pele";

const SOURCE_LIMIT = 50_000;
const OUTPUT_LIMIT = 1_048_576;
const MAX_DIMENSION = 8192;
const MAX_PIXELS = 8_000_000;

self.onmessage = (event) => {
  const data = event.data;
  const id = data?.id;
  try {
    if (!data || typeof data.source !== "string" || data.source.length > SOURCE_LIMIT) {
      self.postMessage({ id, ok: false, reason: "limit" });
      return;
    }

    const width = data.width;
    if (!Number.isFinite(width) || width <= 0 || width > MAX_DIMENSION) {
      self.postMessage({ id, ok: false, reason: "limit" });
      return;
    }

    const fonts = data.fonts && typeof data.fonts === "object" ? data.fonts : {};
    const result = render(data.source, {
      fontFamily: fontName(fonts.sans, "sans-serif"),
      fontFamilyMono: fontName(fonts.mono, "monospace"),
      fontSize: fontSize(fonts.size),
      maxWidth: width,
      responsive: true,
      autoDirection: true,
      links: false,
      images: false,
      limit: SOURCE_LIMIT,
      outputLimit: OUTPUT_LIMIT,
      maxEdges: 500
    });

    if (typeof result.svg !== "string" || result.svg.length > OUTPUT_LIMIT) {
      self.postMessage({ id, ok: false, reason: "limit" });
      return;
    }

    if (
      !Number.isFinite(result.width) ||
      !Number.isFinite(result.height) ||
      result.width <= 0 ||
      result.height <= 0 ||
      result.width > MAX_DIMENSION ||
      result.height > MAX_DIMENSION ||
      result.width * result.height > MAX_PIXELS
    ) {
      self.postMessage({ id, ok: false, reason: "limit" });
      return;
    }

    self.postMessage({
      id,
      ok: true,
      svg: result.svg,
      width: result.width,
      height: result.height
    });
  } catch (error) {
    const reason = error instanceof PeleError
      ? (error.code === "limit" ? "limit" : error.code === "unsupported-diagram" ? "unsupported" : "syntax")
      : "worker";
    self.postMessage({ id, ok: false, reason });
  }
};

function fontName(value, fallback) {
  return typeof value === "string" && value.length > 0 && value.length <= 200 ? value : fallback;
}

function fontSize(value) {
  return Number.isFinite(value) && value > 0 && value <= 200 ? value : 16;
}
