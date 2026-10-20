const PROTOCOL_VERSION = 1;

export class ChromeCdpBridge {
  constructor(chromeApi, sendEnvelope) {
    this.chrome = chromeApi;
    this.sendEnvelope = sendEnvelope;
    this.clients = new Map();
    this.attachedTabs = new Set();
    this.tabRevisions = new Map();
    this.generation = 0;
    this.listenersInstalled = false;
  }

  start() {
    if (this.listenersInstalled) return;
    this.listenersInstalled = true;

    this.chrome.debugger.onEvent.addListener((source, method, params) => {
      this.forwardDebuggerEvent(source, method, params);
    });

    this.chrome.debugger.onDetach.addListener((source, reason) => {
      this.handleDebuggerDetach(source, reason);
    });

    this.chrome.tabs.onCreated.addListener((tab) => this.handleTabCreated(tab));
    this.chrome.tabs.onUpdated.addListener((_tabId, _change, tab) => this.handleTabUpdated(tab));
    this.chrome.tabs.onRemoved.addListener((tabId) => this.handleTabRemoved(tabId));
  }

  async hello(version) {
    this.sendEnvelope({ type: "hello", protocol: PROTOCOL_VERSION, version });
    await this.sendStatus();
  }

  async handleEnvelope(envelope) {
    if (envelope?.type === "stop") {
      await this.stop();
      return;
    }

    if (envelope?.type === "client_disconnected" && typeof envelope.clientId === "string") {
      await this.dropClient(envelope.clientId);
      return;
    }

    if (envelope?.type !== "cdp" || typeof envelope.clientId !== "string") return;

    const message = envelope.message;
    if (!message || typeof message.id !== "number" || typeof message.method !== "string") return;
    const operationGeneration = this.generation;

    try {
      const result = message.sessionId
        ? await this.handleSessionCommand(envelope.clientId, message, operationGeneration)
        : await this.handleBrowserCommand(envelope.clientId, message, operationGeneration);

      if (
        operationGeneration === this.generation &&
        this.clients.has(envelope.clientId)
      ) {
        this.sendCdp(envelope.clientId, { id: message.id, result: result ?? {} });
      }
    } catch (error) {
      if (
        operationGeneration === this.generation &&
        this.clients.has(envelope.clientId)
      ) {
        this.sendCdp(envelope.clientId, {
          id: message.id,
          error: { code: -32000, message: errorMessage(error) },
        });
      }
    }
  }

  async stop() {
    this.generation += 1;
    this.clients.clear();

    const tabs = [...this.attachedTabs];
    this.attachedTabs.clear();

    await Promise.allSettled(
      tabs.map((tabId) => this.chrome.debugger.detach({ tabId })),
    );

    await this.sendStatus();
  }

  async handleBrowserCommand(clientId, message, operationGeneration) {
    const params = message.params || {};
    const client = this.client(clientId);

    switch (message.method) {
      case "Target.setDiscoverTargets":
        client.discover = params.discover === true;
        return {};

      case "Target.setAutoAttach":
        client.autoAttach = params.autoAttach === true;
        return {};

      case "Target.getTargets":
        return { targetInfos: await this.targetInfos() };

      case "Target.getTargetInfo": {
        const tab = await this.getEligibleTab(params.targetId);
        return { targetInfo: targetInfo(tab, this.attachedTabs.has(tab.id)) };
      }

      case "Target.createTarget": {
        const url = eligibleNavigationUrl(params.url) ? params.url : "about:blank";
        const tab = await this.chrome.tabs.create({ url, active: false });
        if (!this.isEligibleTab(tab)) throw new Error("Chrome did not create an eligible tab");
        return { targetId: String(tab.id) };
      }

      case "Target.attachToTarget": {
        const expectedTabId = Number(params.targetId);
        const tabRevision = this.tabRevision(expectedTabId);
        const tab = await this.getEligibleTab(params.targetId);
        this.assertOperationCurrent(clientId, client, operationGeneration);
        if (tabRevision !== this.tabRevision(tab.id)) throw new Error("Chrome target changed");

        await this.attachTab(tab.id, operationGeneration);

        try {
          this.assertOperationCurrent(clientId, client, operationGeneration);
          if (tabRevision !== this.tabRevision(tab.id)) throw new Error("Chrome target changed");

          const currentTab = await this.chrome.tabs.get(tab.id);
          this.assertOperationCurrent(clientId, client, operationGeneration);
          if (
            tabRevision !== this.tabRevision(tab.id) ||
            !this.isEligibleTab(currentTab) ||
            !this.attachedTabs.has(tab.id)
          ) {
            throw new Error("Chrome tab is outside Handbean's allowed scope");
          }
        } catch (error) {
          await this.maybeDetachTab(tab.id);
          throw error;
        }

        const sessionId = topSessionId(clientId, tab.id);
        client.sessions.set(sessionId, { tabId: tab.id, chromeSessionId: null });
        await this.sendStatus();
        return { sessionId };
      }

      case "Target.detachFromTarget":
        await this.detachSession(clientId, params.sessionId);
        return {};

      case "Target.activateTarget": {
        const tab = await this.getEligibleTab(params.targetId);
        this.assertOperationCurrent(clientId, client, operationGeneration);
        await this.chrome.tabs.update(tab.id, { active: true });
        this.assertOperationCurrent(clientId, client, operationGeneration);
        await this.chrome.windows.update(tab.windowId, { focused: true });
        return {};
      }

      case "Target.closeTarget": {
        const tab = await this.getEligibleTab(params.targetId);
        this.assertOperationCurrent(clientId, client, operationGeneration);
        await this.chrome.tabs.remove(tab.id);
        return { success: true };
      }

      case "Browser.getVersion":
        return {
          protocolVersion: "1.3",
          product: "Chrome/HandbeanExtension",
          revision: "phase0",
          userAgent: globalThis.navigator?.userAgent || "Chrome",
          jsVersion: "",
        };

      case "Browser.setDownloadBehavior":
        return {};

      case "Browser.getWindowForTarget": {
        const tab = await this.getEligibleTab(params.targetId);
        const win = await this.chrome.windows.get(tab.windowId);
        return {
          windowId: tab.windowId,
          bounds: {
            left: win.left,
            top: win.top,
            width: win.width,
            height: win.height,
            windowState: win.state,
          },
        };
      }

      case "Browser.close":
        // Closing an agent-browser session must never close the user's Chrome.
        // The WebSocket lifecycle releases this client after the response.
        return {};

      default:
        throw new Error(`Unsupported browser-level CDP method: ${message.method}`);
    }
  }

  async handleSessionCommand(clientId, message, operationGeneration) {
    const client = this.client(clientId);
    const target = client.sessions.get(message.sessionId);
    if (!target) throw new Error("Unknown or stale CDP session");

    if (message.method.startsWith("Target.") && message.method !== "Target.setAutoAttach") {
      throw new Error("Session-scoped Target command is outside Handbean's allowed scope");
    }

    const tab = await this.chrome.tabs.get(target.tabId);
    if (!this.isEligibleTab(tab)) throw new Error("Chrome tab is outside Handbean's allowed scope");
    this.assertOperationCurrent(clientId, client, operationGeneration);
    if (client.sessions.get(message.sessionId) !== target) {
      throw new Error("Unknown or stale CDP session");
    }

    const source = target.chromeSessionId
      ? { tabId: target.tabId, sessionId: target.chromeSessionId }
      : { tabId: target.tabId };

    return await this.chrome.debugger.sendCommand(source, message.method, message.params || {});
  }

  client(clientId) {
    let client = this.clients.get(clientId);
    if (!client) {
      client = { discover: false, autoAttach: false, sessions: new Map(), children: new Map() };
      this.clients.set(clientId, client);
    }
    return client;
  }

  assertOperationCurrent(clientId, client, operationGeneration) {
    if (
      operationGeneration !== this.generation ||
      this.clients.get(clientId) !== client
    ) {
      throw new Error("Stale Chrome control operation");
    }
  }

  tabRevision(tabId) {
    return this.tabRevisions.get(tabId) || 0;
  }

  bumpTabRevision(tabId) {
    this.tabRevisions.set(tabId, this.tabRevision(tabId) + 1);
  }

  async attachTab(tabId, operationGeneration) {
    if (this.attachedTabs.has(tabId)) return;
    await this.chrome.debugger.attach({ tabId }, "1.3");

    if (operationGeneration !== this.generation) {
      await this.chrome.debugger.detach({ tabId }).catch(() => {});
      throw new Error("Stale Chrome control operation");
    }

    this.attachedTabs.add(tabId);
  }

  async detachSession(clientId, sessionId) {
    const client = this.clients.get(clientId);
    const target = client?.sessions.get(sessionId);
    if (!target) return;

    client.sessions.delete(sessionId);
    if (target.chromeSessionId) client.children.delete(target.chromeSessionId);
    await this.maybeDetachTab(target.tabId);
  }

  async dropClient(clientId) {
    const client = this.clients.get(clientId);
    if (!client) return;

    const tabIds = new Set([...client.sessions.values()].map((target) => target.tabId));
    this.clients.delete(clientId);
    await Promise.allSettled([...tabIds].map((tabId) => this.maybeDetachTab(tabId)));
    await this.sendStatus();
  }

  async maybeDetachTab(tabId) {
    const stillUsed = [...this.clients.values()].some((client) =>
      [...client.sessions.values()].some((target) => target.tabId === tabId),
    );

    if (!stillUsed && this.attachedTabs.delete(tabId)) {
      await this.chrome.debugger.detach({ tabId }).catch(() => {});
    }
  }

  async targetInfos() {
    const tabs = await this.chrome.tabs.query({});
    return tabs.filter((tab) => this.isEligibleTab(tab)).map((tab) =>
      targetInfo(tab, this.attachedTabs.has(tab.id)),
    );
  }

  async getEligibleTab(targetId) {
    const tabId = Number(targetId);
    if (!Number.isInteger(tabId)) throw new Error("Unknown Chrome target");

    const tab = await this.chrome.tabs.get(tabId);
    if (!this.isEligibleTab(tab)) throw new Error("Chrome tab is outside Handbean's allowed scope");
    return tab;
  }

  isEligibleTab(tab) {
    return Boolean(
      tab &&
        Number.isInteger(tab.id) &&
        tab.incognito !== true &&
        eligiblePageUrl(tab.url || tab.pendingUrl || ""),
    );
  }

  forwardDebuggerEvent(source, method, params = {}) {
    if (!Number.isInteger(source?.tabId)) return;

    for (const [clientId, client] of this.clients) {
      const parent = this.sessionForTab(client, source.tabId, source.sessionId);
      if (!parent) continue;

      const translated = translateSessionParams(clientId, source.tabId, method, params, client);
      this.sendCdp(clientId, { method, params: translated, sessionId: parent });
    }
  }

  handleDebuggerDetach(source, reason) {
    const tabId = source?.tabId;
    if (!Number.isInteger(tabId)) return;
    this.attachedTabs.delete(tabId);

    for (const [clientId, client] of this.clients) {
      const sessions = [...client.sessions.entries()].filter(([, target]) => target.tabId === tabId);
      for (const [sessionId, target] of sessions) {
        client.sessions.delete(sessionId);
        if (target.chromeSessionId) client.children.delete(target.chromeSessionId);
        this.sendCdp(clientId, {
          method: "Target.detachedFromTarget",
          params: { sessionId, targetId: String(tabId), reason },
        });
      }
    }

    this.sendStatus();
  }

  sessionForTab(client, tabId, chromeSessionId) {
    if (chromeSessionId) {
      const existing = client.children.get(chromeSessionId);
      if (existing) return existing;
    }

    for (const [sessionId, target] of client.sessions) {
      if (target.tabId === tabId && target.chromeSessionId === (chromeSessionId || null)) {
        return sessionId;
      }
    }

    return null;
  }

  handleTabCreated(tab) {
    if (!this.isEligibleTab(tab)) return;
    this.broadcastTargetEvent("Target.targetCreated", {
      targetInfo: targetInfo(tab, this.attachedTabs.has(tab.id)),
    });
    this.sendStatus();
  }

  handleTabUpdated(tab) {
    if (!this.isEligibleTab(tab)) {
      if (Number.isInteger(tab?.id)) {
        this.bumpTabRevision(tab.id);
        if (this.attachedTabs.has(tab.id)) this.revokeTab(tab.id);
      }
      return;
    }

    this.broadcastTargetEvent("Target.targetInfoChanged", {
      targetInfo: targetInfo(tab, this.attachedTabs.has(tab.id)),
    });
  }

  async revokeTab(tabId) {
    const wasAttached = this.attachedTabs.delete(tabId);

    for (const [clientId, client] of this.clients) {
      const sessions = [...client.sessions.entries()].filter(([, target]) => target.tabId === tabId);
      for (const [sessionId, target] of sessions) {
        client.sessions.delete(sessionId);
        if (target.chromeSessionId) client.children.delete(target.chromeSessionId);
        this.sendCdp(clientId, {
          method: "Target.detachedFromTarget",
          params: { sessionId, targetId: String(tabId), reason: "restricted_navigation" },
        });
      }
    }

    if (wasAttached) await this.chrome.debugger.detach({ tabId }).catch(() => {});

    this.broadcastTargetEvent("Target.targetDestroyed", { targetId: String(tabId) });
    await this.sendStatus();
  }

  handleTabRemoved(tabId) {
    this.bumpTabRevision(tabId);
    this.attachedTabs.delete(tabId);
    this.broadcastTargetEvent("Target.targetDestroyed", { targetId: String(tabId) });

    for (const client of this.clients.values()) {
      for (const [sessionId, target] of client.sessions) {
        if (target.tabId === tabId) {
          client.sessions.delete(sessionId);
          if (target.chromeSessionId) client.children.delete(target.chromeSessionId);
        }
      }
    }

    this.sendStatus();
  }

  broadcastTargetEvent(method, params) {
    for (const [clientId, client] of this.clients) {
      if (client.discover) this.sendCdp(clientId, { method, params });
    }
  }

  async sendStatus() {
    try {
      const tabs = await this.chrome.tabs.query({});
      this.sendEnvelope({ type: "status", tabs: tabs.filter((tab) => this.isEligibleTab(tab)).length });
    } catch (_error) {
      this.sendEnvelope({ type: "status", tabs: 0 });
    }
  }

  sendCdp(clientId, message) {
    this.sendEnvelope({ type: "cdp", clientId, message });
  }
}

function targetInfo(tab, attached) {
  return {
    targetId: String(tab.id),
    type: "page",
    title: tab.title || "",
    url: tab.url || tab.pendingUrl || "about:blank",
    attached,
    canAccessOpener: false,
  };
}

function topSessionId(clientId, tabId) {
  return `hb:${clientId}:${tabId}`;
}

function childSessionId(clientId, chromeSessionId) {
  return `hb-child:${clientId}:${chromeSessionId}`;
}

function translateSessionParams(clientId, tabId, method, params, client) {
  if (!params || typeof params !== "object" || typeof params.sessionId !== "string") return params;

  const translated = { ...params };
  const chromeSessionId = params.sessionId;
  const knownExternal = client.children.get(chromeSessionId);
  const external = knownExternal || childSessionId(clientId, chromeSessionId);
  translated.sessionId = external;

  if (method === "Target.attachedToTarget") {
    client.children.set(chromeSessionId, external);
    client.sessions.set(external, { tabId, chromeSessionId });
  } else if (method === "Target.detachedFromTarget" && knownExternal) {
    client.children.delete(chromeSessionId);
    client.sessions.delete(knownExternal);
  }

  return translated;
}

function eligiblePageUrl(url) {
  return /^https?:\/\//i.test(url) || url === "about:blank";
}

function eligibleNavigationUrl(url) {
  return typeof url === "string" && eligiblePageUrl(url);
}

function errorMessage(error) {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "Chrome debugger command failed";
}
