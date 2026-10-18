const BrowserSurface = {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.markers = this.el.querySelector("[data-markers], #browser-markers");
    this.metadata = {
      deviceWidth: this.el.clientWidth || 1,
      deviceHeight: this.el.clientHeight || 1,
      pageScaleFactor: 1,
      scrollOffsetX: 0,
      scrollOffsetY: 0
    };
    this.annotations = [];
    this.el.tabIndex = 0;
    this.handleEvent("browser_frame", (frame) => {
      this.draw(frame);
    });
    this.handleEvent("browser_markers", (payload) => {
      this.annotations = payload.annotations || [];
      this.renderMarkers();
    });
    this.onClick = (event) => this.click(event);
    this.onKey = (event) => this.key(event);
    this.onWheel = (event) => this.wheel(event);
    this.el.addEventListener("click", this.onClick, true);
    this.el.addEventListener("keydown", this.onKey);
    this.el.addEventListener("wheel", this.onWheel, {passive: false});
    this.resize = new ResizeObserver(() => this.queueResize());
    this.resize.observe(this.el);
  },

  updated() {
    this.renderMarkers();
  },

  destroyed() {
    this.resize?.disconnect();
    clearTimeout(this.resizeTimer);
    this.el.removeEventListener("click", this.onClick, true);
    this.el.removeEventListener("keydown", this.onKey);
    this.el.removeEventListener("wheel", this.onWheel);
  },

  draw(frame) {
    if (!frame || !frame.data) return;
    this.metadata = frame.metadata || this.metadata;
    const img = new Image();
    img.onload = () => {
      const canvas = this.canvas;
      const width = this.el.clientWidth;
      const height = this.el.clientHeight;
      if (!canvas || width < 1 || height < 1) return;
      canvas.width = width;
      canvas.height = height;
      canvas.getContext("2d").drawImage(img, 0, 0, width, height);
      this.renderMarkers();
    };
    const data = String(frame.data);
    img.src = data.startsWith("data:") ? data : `data:image/jpeg;base64,${data}`;
  },

  click(event) {
    if (event.target.closest("[data-marker]")) return;
    const point = this.point(event);
    if (this.designing()) {
      event.preventDefault();
      event.stopImmediatePropagation();
      this.pushEventTo(this.el, "browser_mark", point);
    } else {
      this.pushEventTo(this.el, "browser_pointer", point);
    }
  },

  key(event) {
    if (this.designing() || event.target.closest("input, textarea")) return;
    event.preventDefault();
    this.pushEventTo(this.el, "browser_key", {key: event.key});
  },

  wheel(event) {
    if (this.designing()) return;
    event.preventDefault();
    const point = this.point(event);
    this.pushEventTo(this.el, "browser_wheel", {
      ...point,
      delta_x: event.deltaX,
      delta_y: event.deltaY
    });
  },

  queueResize() {
    clearTimeout(this.resizeTimer);
    this.resizeTimer = setTimeout(() => {
      const rect = this.el.getBoundingClientRect();
      this.pushEventTo(this.el, "browser_viewport", {
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      });
    }, 150);
  },

  designing() {
    return this.el.dataset.design === "true";
  },

  point(event) {
    const rect = this.el.getBoundingClientRect();
    const scale = this.metadata.pageScaleFactor || 1;
    const cssWidth = (this.metadata.deviceWidth || rect.width) / scale;
    const cssHeight = (this.metadata.deviceHeight || rect.height) / scale;
    const x = rect.width ? ((event.clientX - rect.left) / rect.width) * cssWidth : 0;
    const y = rect.height ? ((event.clientY - rect.top) / rect.height) * cssHeight : 0;
    return {x, y};
  },

  renderMarkers() {
    const layer = this.markers;
    if (!layer) return;
    layer.replaceChildren();
    const rect = this.el.getBoundingClientRect();
    const scale = this.metadata.pageScaleFactor || 1;
    const cssWidth = (this.metadata.deviceWidth || rect.width) / scale;
    const cssHeight = (this.metadata.deviceHeight || rect.height) / scale;
    const scrollX = this.metadata.scrollOffsetX || 0;
    const scrollY = this.metadata.scrollOffsetY || 0;
    const scaleX = cssWidth ? rect.width / cssWidth : 1;
    const scaleY = cssHeight ? rect.height / cssHeight : 1;

    for (const mark of this.annotations) {
      const node = document.createElement("div");
      node.dataset.marker = String(mark.index);
      node.style.position = "absolute";
      node.style.left = `${(mark.page_x - scrollX) * scaleX}px`;
      node.style.top = `${(mark.page_y - scrollY) * scaleY}px`;
      node.style.pointerEvents = "auto";
      node.style.display = "flex";
      node.style.alignItems = "center";
      node.style.gap = "4px";

      const badge = document.createElement("span");
      badge.textContent = String(mark.index);
      badge.style.width = "22px";
      badge.style.height = "22px";
      badge.style.borderRadius = "999px";
      badge.style.background = "#6d28d9";
      badge.style.color = "white";
      badge.style.font = "700 12px sans-serif";
      badge.style.display = "flex";
      badge.style.alignItems = "center";
      badge.style.justifyContent = "center";

      const input = document.createElement("input");
      input.type = "text";
      input.value = mark.comment || "";
      input.placeholder = "Comment";
      input.style.font = "12px sans-serif";
      input.style.padding = "2px 6px";
      input.style.borderRadius = "6px";
      input.style.border = "1px solid #6d28d9";
      input.style.background = "white";
      input.style.color = "#111";
      input.addEventListener("change", () => {
        this.pushEventTo(this.el, "browser_comment", {index: mark.index, comment: input.value});
      });

      const remove = document.createElement("button");
      remove.type = "button";
      remove.textContent = "×";
      remove.style.pointerEvents = "auto";
      remove.addEventListener("click", (event) => {
        event.stopPropagation();
        this.pushEventTo(this.el, "browser_remove", {index: mark.index});
      });

      node.append(badge, input, remove);
      layer.append(node);
    }
  }
};

export { BrowserSurface };
