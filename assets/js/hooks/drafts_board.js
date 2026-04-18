// DraftsBoard hook — native HTML5 drag-and-drop across priority columns.
//
// Mounted on each column element (`#column-<priority>`). Uses `dragstart`,
// `dragover`, `drop`, and `dragend` to reorder draft cards and push a
// `reorder_draft` event to the server with the moved draft's id, its new
// priority, and the ids of its new neighbors (before/after).

const ITEM_SELECTOR = "[data-draft-id]"

const DraftsBoard = {
  mounted() {
    this.priority = this.el.dataset.priority
    this.onDragStart = this.handleDragStart.bind(this)
    this.onDragOver = this.handleDragOver.bind(this)
    this.onDragLeave = this.handleDragLeave.bind(this)
    this.onDrop = this.handleDrop.bind(this)
    this.onDragEnd = this.handleDragEnd.bind(this)

    this.el.addEventListener("dragstart", this.onDragStart)
    this.el.addEventListener("dragover", this.onDragOver)
    this.el.addEventListener("dragleave", this.onDragLeave)
    this.el.addEventListener("drop", this.onDrop)
    this.el.addEventListener("dragend", this.onDragEnd)
  },

  destroyed() {
    this.el.removeEventListener("dragstart", this.onDragStart)
    this.el.removeEventListener("dragover", this.onDragOver)
    this.el.removeEventListener("dragleave", this.onDragLeave)
    this.el.removeEventListener("drop", this.onDrop)
    this.el.removeEventListener("dragend", this.onDragEnd)
  },

  handleDragStart(event) {
    const card = event.target.closest(ITEM_SELECTOR)
    if (!card) return
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", card.dataset.draftId)
    card.classList.add("opacity-40")
    DraftsBoard._draggingId = card.dataset.draftId
  },

  handleDragOver(event) {
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    this.el.classList.add("ring-2", "ring-primary/40")
  },

  handleDragLeave(event) {
    if (event.target === this.el) {
      this.el.classList.remove("ring-2", "ring-primary/40")
    }
  },

  handleDrop(event) {
    event.preventDefault()
    this.el.classList.remove("ring-2", "ring-primary/40")

    const draftId =
      event.dataTransfer.getData("text/plain") ||
      DraftsBoard._draggingId

    if (!draftId) return

    const cards = Array.from(this.el.querySelectorAll(ITEM_SELECTOR))
      .filter((c) => c.dataset.draftId !== draftId)

    const y = event.clientY
    let beforeId = null
    let afterId = null

    for (const card of cards) {
      const rect = card.getBoundingClientRect()
      const midpoint = rect.top + rect.height / 2
      if (y < midpoint) {
        afterId = card.dataset.draftId
        break
      } else {
        beforeId = card.dataset.draftId
      }
    }

    this.pushEvent("reorder_draft", {
      draft_id: draftId,
      priority: this.priority,
      before_id: beforeId,
      after_id: afterId,
    })
  },

  handleDragEnd() {
    this.el.classList.remove("ring-2", "ring-primary/40")
    const card = this.el.querySelector(".opacity-40")
    if (card) card.classList.remove("opacity-40")
    DraftsBoard._draggingId = null
  },
}

export default DraftsBoard
