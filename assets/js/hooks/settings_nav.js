export const SettingsNav = {
  mounted() {
    this.revealActiveTab();
  },

  updated() {
    this.revealActiveTab();
  },

  revealActiveTab() {
    const active = this.el.querySelector("[aria-current='page']");
    if (!active || active === this.activeTab) return;

    this.activeTab = active;
    requestAnimationFrame(() => {
      active.scrollIntoView({ block: "nearest", inline: "center" });
    });
  }
};
