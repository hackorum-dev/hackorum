import { Controller } from "@hotwired/stimulus"

const MOBILE_BREAKPOINT = "(max-width: 900px)"

export default class extends Controller {
  static targets = ["container", "menu", "overflow", "overflowMenu", "item"]

  connect() {
    this.mediaQuery = window.matchMedia(MOBILE_BREAKPOINT)
    this._resizeHandler = this.layout.bind(this)
    window.addEventListener("resize", this._resizeHandler)
    this.storePositions()
    this.layout()
  }

  disconnect() {
    window.removeEventListener("resize", this._resizeHandler)
  }

  storePositions() {
    this.positions = new Map()
    this.orderedItems = [...this.itemTargets]
    this.orderedItems.forEach((item) => {
      const parent = item.parentElement
      const index = Array.from(parent.children).indexOf(item)
      this.positions.set(item, { parent, index })
    })
  }

  restoreItems() {
    const byParent = new Map()
    this.positions.forEach((position, item) => {
      if (!byParent.has(position.parent)) {
        byParent.set(position.parent, [])
      }
      byParent.get(position.parent).push({ item, index: position.index })
    })

    byParent.forEach((items, parent) => {
      items
        .sort((a, b) => a.index - b.index)
        .forEach(({ item, index }) => {
          const ref = parent.children[index] || null
          parent.insertBefore(item, ref)
        })
    })
  }

  hideOverflow() {
    this.overflowTarget.classList.remove("is-visible")
    this.overflowTarget.open = false
  }

  showOverflow() {
    this.overflowTarget.classList.add("is-visible")
  }

  layout() {
    if (!this.hasContainerTarget || !this.hasOverflowMenuTarget) return

    this.restoreItems()
    this.overflowMenuTarget.innerHTML = ""
    this.hideOverflow()

    if (this.mediaQuery.matches) {
      return
    }

    const fits = this.containerTarget.scrollWidth <= this.containerTarget.clientWidth
    if (fits) return

    this.showOverflow()

    for (let i = this.orderedItems.length - 1; i >= 0; i -= 1) {
      if (this.containerTarget.scrollWidth <= this.containerTarget.clientWidth) break
      const item = this.orderedItems[i]
      if (this.overflowMenuTarget.contains(item)) continue
      this.overflowMenuTarget.insertBefore(item, this.overflowMenuTarget.firstChild)
    }

    if (!this.overflowMenuTarget.children.length) {
      this.hideOverflow()
    }
  }
}
