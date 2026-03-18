import Sortable from "../../vendor/sortable"

export const SortableHook = {
  mounted() {
    const group = this.el.closest("[data-board-group]")?.dataset.boardGroup || "board"

    this.sortable = new Sortable(this.el, {
      group: group,
      animation: 150,
      ghostClass: "opacity-30",
      dragClass: "shadow-xl",
      handle: "[data-id]",
      draggable: "[data-id]",
      onEnd: (evt) => {
        const id = evt.item.dataset.id
        const toColumn = evt.to.dataset.column
        const newIndex = evt.newIndex

        this.pushEvent("card_moved", {
          id: id,
          to: toColumn,
          index: newIndex
        })
      }
    })
  },

  destroyed() {
    if (this.sortable) {
      this.sortable.destroy()
    }
  }
}
