export const ScheduleCountdown = {
  mounted() {
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  },
  updated() {
    this.tick()
  },
  destroyed() {
    clearInterval(this.timer)
  },
  tick() {
    const at = Date.parse(this.el.dataset.at)
    if (Number.isNaN(at)) return
    const seconds = Math.round((at - Date.now()) / 1000)
    if (seconds > 0) {
      this.el.textContent = `下次还要 ${formatAhead(seconds)}`
      return
    }

    this.el.textContent = "即将运行"
    const target = this.el.ownerDocument?.getElementById(this.el.dataset.dueTarget)
    if (target && this.el.dataset.dueLines) target.textContent = this.el.dataset.dueLines
  }
}

function formatAhead(seconds) {
  const minutes = Math.max(1, Math.round(seconds / 60))
  return `${minutes} 分钟`
}
