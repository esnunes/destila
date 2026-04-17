const LocalTime = {
  mounted() { this.format() },
  updated() { this.format() },
  format() {
    const ts = this.el.dataset.ts
    if (!ts) return
    const d = new Date(ts)
    if (isNaN(d.getTime())) return
    this.el.textContent = d.toLocaleString([], {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false
    })
  }
}

export default LocalTime
