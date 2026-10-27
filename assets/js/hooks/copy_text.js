export function copyText(text, ownerDocument = document) {
  if (!text) return Promise.resolve(false);

  const clipboard = ownerDocument.defaultView?.navigator?.clipboard;
  if (clipboard && typeof clipboard.writeText === "function") {
    try {
      return Promise.resolve(clipboard.writeText(text))
        .then(() => true)
        .catch(() => fallbackCopy(text, ownerDocument));
    } catch {
      return Promise.resolve(fallbackCopy(text, ownerDocument));
    }
  }

  return Promise.resolve(fallbackCopy(text, ownerDocument));
}

function fallbackCopy(text, ownerDocument) {
  let input;

  try {
    input = ownerDocument.createElement("textarea");
    input.value = text;
    input.setAttribute("readonly", "");
    input.style.position = "fixed";
    input.style.left = "-9999px";
    ownerDocument.body.appendChild(input);
    input.select();

    return typeof ownerDocument.execCommand === "function" && ownerDocument.execCommand("copy");
  } catch {
    return false;
  } finally {
    input?.remove();
  }
}

export const CopyText = {
  mounted() {
    this.onCopy = () => {
      const text = this.el.dataset.copy || "";
      copyText(text, this.el.ownerDocument).then((copied) => {
        if (!copied) return;

        this.el.dataset.copied = "true";
        window.setTimeout(() => this.el.removeAttribute("data-copied"), 1500);
      });
    };

    this.el.addEventListener("click", this.onCopy);
  },

  destroyed() {
    this.el.removeEventListener("click", this.onCopy);
  },
};

export default CopyText;
