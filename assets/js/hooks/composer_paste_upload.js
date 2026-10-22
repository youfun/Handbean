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
    this.commandIntent = null;

    this.commandIntentStorageKey = () =>
      this.el.dataset.commandIntentKey || "handbean:workspace-command-intent";

    this.commandIntentScope = () => this.el.dataset.commandIntentScope || "new:unknown";

    this.commandIntentInput = () =>
      this.el.closest("form")?.querySelector("input[name='workspace_command_operation_id']");

    this.newCommandIntentId = () =>
      globalThis.crypto?.randomUUID?.() ||
      "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (char) => {
        const random = Math.floor(Math.random() * 16);
        return (char === "x" ? random : (random & 0x3) | 0x8).toString(16);
      });

    this.clearCommandIntent = () => {
      this.commandIntent = null;
      const hidden = this.commandIntentInput();
      if (hidden) hidden.value = "";

      try {
        window.sessionStorage.removeItem(this.commandIntentStorageKey());
      } catch (_err) {
        // Storage may be unavailable in hardened/private browser contexts.
      }
    };

    this.syncCommandIntent = () => {
      const hidden = this.commandIntentInput();
      if (!hidden) return;

      const value = String(this.el.value || "").trim();
      if (!value.startsWith("!")) {
        this.clearCommandIntent();
        return;
      }

      let stored = this.commandIntent;
      if (!stored) {
        try {
          const serialized = window.sessionStorage.getItem(this.commandIntentStorageKey());
          if (serialized) stored = JSON.parse(serialized);
        } catch (_err) {
          // Keep the mounted hook's in-memory intent when storage is unavailable.
        }
      }

      const scope = this.commandIntentScope();
      const followsCreatedConversation =
        stored?.scope?.startsWith("new:") && !scope.startsWith("new:");
      const sameScope = stored?.scope === scope || followsCreatedConversation;
      const id =
        stored?.value === value && stored?.id && sameScope
          ? stored.id
          : this.newCommandIntentId();

      const intent = { value, id, scope };
      this.commandIntent = intent;
      hidden.value = id;

      try {
        window.sessionStorage.setItem(
          this.commandIntentStorageKey(),
          JSON.stringify(intent),
        );
      } catch (_err) {
        // The hook's in-memory intent keeps this mounted form stable.
      }
    };

    const setInput = ({ value }) => {
      this.el.value = String(value || "");
      this.syncCommandIntent();
      this.el.focus();
    };
    this.handleEvent?.("composer:set-input", setInput);
    this.handleEvent?.("prefill-subagent-follow-up", setInput);
    this.handleEvent?.("user-message-sent", () => this.clearCommandIntent());
    this.syncCommandIntent();

    this.onInput = () => this.syncCommandIntent();

    this.onKeyDown = (e) => {
      if (e.key !== "Enter" || e.isComposing || e.keyCode === 229) return;

      if (e.shiftKey) return;

      const form = this.el.closest("form");
      if (!form) return;

      e.preventDefault();

      if (e.ctrlKey || e.metaKey) {
        if (typeof this.pushEvent === "function") {
          this.pushEvent("queue_message", {
            message: this.el.value,
            workspace_command_operation_id: this.commandIntentInput()?.value || "",
          });
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

    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("keydown", this.onKeyDown);
    this.el.addEventListener("paste", this.onPaste);
  },

  updated() {
    this.syncCommandIntent?.();
  },

  destroyed() {
    if (this.onInput) this.el.removeEventListener("input", this.onInput);
    if (this.onKeyDown) this.el.removeEventListener("keydown", this.onKeyDown);
    if (this.onPaste) this.el.removeEventListener("paste", this.onPaste);
    this.commandIntent = null;
    this.clearCommandIntent = null;
    this.commandIntentScope = null;
    this.newCommandIntentId = null;
    this.syncCommandIntent = null;
  },
};

export default ComposerPasteUpload;
