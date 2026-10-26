/**
 * WorkspaceAddDrop hook
 *
 * Drop target is only the "add workspace" row. Folders open the existing add
 * dialog with a native path when the host exposes one. Files are rejected in
 * the row and never reach the dialog.
 */

export function nativeFilePath(file) {
  if (!file || typeof file !== "object") return "";
  const path = file.path;
  return typeof path === "string" ? path.trim() : "";
}

export function pathFromUriList(value) {
  const line = String(value || "")
    .split("\n")
    .map((entry) => entry.trim())
    .find((entry) => entry && !entry.startsWith("#"));
  if (!line) return "";
  try {
    const url = new URL(line);
    if (url.protocol !== "file:") return "";
    const path = decodeURIComponent(url.pathname);
    return /^\/[A-Za-z]:\//.test(path) ? path.slice(1) : path;
  } catch (_err) {
    return "";
  }
}

export function directoryDropFromDataTransfer(dataTransfer) {
  const items = dataTransfer?.items;
  if (items && items.length) {
    let sawFile = false;
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index];
      if (item.kind !== "file") continue;
      const entry = item.webkitGetAsEntry?.();
      const file = typeof item.getAsFile === "function" ? item.getAsFile() : null;
      const path = nativeFilePath(file);
      if (entry?.isDirectory) return { kind: "directory", path };
      if (entry?.isFile) {
        sawFile = true;
        continue;
      }
      if (file?.type) {
        sawFile = true;
        continue;
      }
      if (path) return { kind: "directory", path };
    }
    if (sawFile) return { kind: "file" };
  }

  const files = dataTransfer?.files;
  if (files && files.length) {
    const file = files[0];
    const path = nativeFilePath(file);
    if (file?.type) return { kind: "file" };
    if (path) return { kind: "directory", path };
  }

  const uriPath = pathFromUriList(dataTransfer?.getData?.("text/uri-list"));
  if (uriPath) return { kind: "directory", path: uriPath };

  return { kind: "empty" };
}

export const WorkspaceAddDrop = {
  mounted() {
    this.dragDepth = 0;
    this.reject = false;

    this.clearDropState = () => {
      this.dragDepth = 0;
      this.reject = false;
      this.el.classList.remove("is-dragover", "is-reject");
    };

    this.setDropState = (reject) => {
      this.reject = reject;
      this.el.classList.add("is-dragover");
      this.el.classList.toggle("is-reject", reject);
    };

    this.onDragEnter = (event) => {
      event.preventDefault();
      this.dragDepth += 1;
      const drop = directoryDropFromDataTransfer(event.dataTransfer);
      this.setDropState(drop.kind === "file");
    };

    this.onDragOver = (event) => {
      event.preventDefault();
      if (event.dataTransfer) {
        event.dataTransfer.dropEffect = this.reject ? "none" : "copy";
      }
    };

    this.onDragLeave = (event) => {
      if (event.relatedTarget && this.el.contains(event.relatedTarget)) return;
      this.dragDepth = Math.max(0, this.dragDepth - 1);
      if (this.dragDepth === 0) this.clearDropState();
    };

    this.onDrop = (event) => {
      event.preventDefault();
      event.stopPropagation();
      const drop = directoryDropFromDataTransfer(event.dataTransfer);
      this.clearDropState();
      if (drop.kind !== "directory") return;
      this.pushEvent("drop_workspace_path", { path: drop.path || "" });
    };

    this.el.addEventListener("dragenter", this.onDragEnter);
    this.el.addEventListener("dragover", this.onDragOver);
    this.el.addEventListener("dragleave", this.onDragLeave);
    this.el.addEventListener("drop", this.onDrop);
  },

  destroyed() {
    this.el.removeEventListener("dragenter", this.onDragEnter);
    this.el.removeEventListener("dragover", this.onDragOver);
    this.el.removeEventListener("dragleave", this.onDragLeave);
    this.el.removeEventListener("drop", this.onDrop);
  },
};
