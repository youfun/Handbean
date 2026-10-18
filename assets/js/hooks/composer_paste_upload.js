/**
 * ComposerPasteUpload hook
 *
 * Enables pasting images (Cmd/Ctrl+V) directly into a LiveView upload entry.
 *
 * Requires:
 * - `phx-hook="ComposerPasteUpload"` on the <textarea>
 * - `data-upload-name="images"` on the same element
 *
 * Behavior:
 * - Enter submits the surrounding form (running: steer; idle: new run).
 * - Shift+Enter inserts a newline.
 * - Ctrl/Cmd+Enter queues a follow-up (`queue_message`).
 * - If clipboard contains image files: prevent default (avoid gibberish in textarea)
 *   and upload those image files into the LiveView upload.
 * - If clipboard contains only text: do nothing (default paste behavior).
 * - If clipboard contains both text and images: do NOT prevent default; let text paste
 *   occur, and also upload images.
 */
export const ComposerPasteUpload = {
  mounted() {
    this.handleEvent?.("prefill-subagent-follow-up", ({ value }) => {
      this.el.value = String(value || "");
      this.el.focus();
    });

    this.onKeyDown = (e) => {
      if (e.key !== "Enter" || e.isComposing || e.keyCode === 229) return;

      if (e.shiftKey) return;

      const form = this.el.closest("form");
      if (!form) return;

      e.preventDefault();

      if (e.ctrlKey || e.metaKey) {
        if (typeof this.pushEvent === "function") {
          this.pushEvent("queue_message", { message: this.el.value });
        }
        return;
      }

      if (typeof form.requestSubmit === "function") {
        form.requestSubmit();
        return;
      }

      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    };

    this.onPaste = (e) => {
      const uploadName = this.el.dataset.uploadName;
      if (!uploadName) return;

      const dt = e.clipboardData;
      if (!dt) return;

      const files = Array.from(dt.files || []).filter((f) => f && f.type && f.type.startsWith("image/"));
      const itemFiles = Array.from(dt.items || [])
        .filter((item) => item && item.kind === "file" && item.type && item.type.startsWith("image/"))
        .map((item) => item.getAsFile())
        .filter((f) => f && f.type && f.type.startsWith("image/"));
      const images = files.length > 0 ? files : itemFiles;
      if (images.length === 0) return;

      const hasText = Array.from(dt.items || []).some((item) => item && item.kind === "string" && item.type === "text/plain");
      if (!hasText) e.preventDefault();

      try {
        this.upload(uploadName, images);
      } catch (_err) {
        // ignore; LiveView will show errors on the upload entries if needed
      }
    };

    this.el.addEventListener("keydown", this.onKeyDown);
    this.el.addEventListener("paste", this.onPaste);
  },

  destroyed() {
    if (this.onKeyDown) this.el.removeEventListener("keydown", this.onKeyDown);
    if (this.onPaste) this.el.removeEventListener("paste", this.onPaste);
  },
};

export default ComposerPasteUpload;
