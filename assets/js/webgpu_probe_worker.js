self.addEventListener("connect", (event) => {
  event.ports[0].postMessage("ready");
});
