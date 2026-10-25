import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/handbean";
import { StreamingMarkdown } from "./hooks/streaming_markdown.js";
import { ChatScroll } from "./hooks/chat_scroll.js";
import { ConversationNav } from "./hooks/conversation_nav.js";
import { ConversationSearch } from "./hooks/conversation_search.js";
import { ComposerPasteUpload } from "./hooks/composer_paste_upload.js";
import { ComposerSpeech } from "./hooks/composer_speech.js";
import { WorkspacePanel } from "./hooks/workspace_panel.js";
import { FilePreview, FileTabs, FileImage } from "./hooks/file_preview.js";
import { CopyText } from "./hooks/copy_text.js";
import { ConversationContextMenu } from "./hooks/conversation_context_menu.js";
import { ConversationHover } from "./hooks/conversation_hover.js";
import { ConversationActivity } from "./hooks/conversation_activity.js";
import { ScheduleCountdown } from "./hooks/schedule_countdown.js";
import { BoundSelect, ModelPicker } from "./hooks/model_picker.js";
import { bootWebPush } from "./web_push.js";
import { bootPWAInstall } from "./pwa_install.js";
import { createConnectionStatus } from "./connection_status.js";

const ConversationSidebar = {
  ...ConversationHover,
  ...ConversationActivity,
  mounted() {
    ConversationHover.mounted.call(this);
    ConversationActivity.mounted.call(this);
  },
  updated() {
    ConversationHover.updated.call(this);
    ConversationActivity.updated.call(this);
  },
  destroyed() {
    ConversationHover.destroyed.call(this);
    ConversationActivity.destroyed.call(this);
  }
};
import { LocalWebGPUProbe } from "./hooks/local_webgpu_probe.js";
import { BrowserSurface } from "./hooks/browser_surface.js";
import { GhosttyTerminal } from "../vendor/ghostty.js";
import { installImageLightbox } from "./image_lightbox.js";

// Server-rendered data-theme is the source of truth. Do not replace it
// with a localStorage default, or a saved dark/system theme never paints.
const serverTheme = document.documentElement.getAttribute("data-theme");
if (!serverTheme) {
  let theme = "light";
  try {
    theme = localStorage.getItem("handbean-theme") || "light";
  } catch (_) {}
  document.documentElement.setAttribute("data-theme", theme);
}
installImageLightbox();
bootPWAInstall();
bootWebPush();
const connectionStatus = createConnectionStatus(document.getElementById("connection-status"), window);
const bindConnectionStatus = () => connectionStatus.bind(document.querySelector("[data-phx-main]"));
window.addEventListener("phx:page-loading-stop", bindConnectionStatus);
window.addEventListener("phx:scroll_to_file_change", ({ detail }) => {
  requestAnimationFrame(() => {
    document.getElementById(detail.id)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  });
});

// MobHook — Mob LiveView bridge. Native WebView injects window.mob pointing
// at the NIF. In LiveView mode this hook replaces it so handle_event/3 in
// LiveView receives JS messages. Requires #mob-bridge in root.html.heex.
function applyTheme(theme) {
  if (!theme) return;
  document.documentElement.setAttribute("data-theme", theme);
  try { localStorage.setItem("handbean-theme", theme); } catch (_) {}
}

const ThemeBridge = {
  mounted() {
    this.handleEvent("set-theme", ({theme}) => applyTheme(theme));
  }
};

const MobHook = {
  mounted() {
    this.handleEvent("set-theme", ({theme}) => applyTheme(theme));
    window.mob = {
      send: (data) => this.pushEvent("mob_message", data),
      onMessage: (handler) => this.handleEvent("mob_push", handler),
      _dispatch: () => {}
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
let Hooks = { ...colocatedHooks, StreamingMarkdown, ChatScroll, ConversationNav, ConversationSearch, ComposerPasteUpload, ComposerSpeech, WorkspacePanel, FilePreview, FileTabs, FileImage, CopyText, ConversationContextMenu, ConversationActivity, ConversationSidebar, LocalWebGPUProbe, GhosttyTerminal, ThemeBridge, MobHook, BrowserSurface, ScheduleCountdown, ModelPicker, BoundSelect };

try {
  let liveSocket = new LiveSocket("/live", Socket, {
    hooks: Hooks,
    params: {
      _csrf_token: csrfToken,
      time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone
    },
    longPollFallbackMs: 2500
  });

  // LiveView turns on diff logging for localhost. Keep the console quiet.
  liveSocket.disableDebug();
  bindConnectionStatus();
  liveSocket.connect();
  window.liveSocket = liveSocket;
  window.addEventListener("phx:scroll-to-run", (event) => {
    const runId = event.detail && event.detail.run_id;
    if (!runId) return;
    const node = document.querySelector(`[data-run-id="${CSS.escape(runId)}"]`);
    if (node) node.scrollIntoView({behavior: "smooth", block: "center"});
  });
} catch (error) {
  console.error("Handbean LiveSocket failed to start", error);
}
