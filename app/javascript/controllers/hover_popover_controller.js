import { Controller } from "@hotwired/stimulus"

// Adds a small delay before hiding popovers so users can move the cursor into them.
//
// The popover is moved to <body> and pinned with `position: fixed` while open,
// instead of staying absolutely positioned inside the table row. Safari ignores
// z-index on <tr> elements once the table uses border-collapse: collapse, so a
// popover left inside the row rendered underneath the rows below it.
export default class extends Controller {
  static targets = ["popover"]
  static values = { delay: Number }

  connect() {
    this.hideTimeout = null
    this.delay = this.delayValue || 150
    this.homeParent = null
    this.homeNextSibling = null
    this.popover = this.hasPopoverTarget ? this.popoverTarget : null
    this.onScroll = () => this._closeImmediately()

    if (this.popover) {
      this.onPopoverEnter = () => this.show()
      this.onPopoverLeave = () => this.scheduleHide()
      this.popover.addEventListener("mouseenter", this.onPopoverEnter)
      this.popover.addEventListener("mouseleave", this.onPopoverLeave)
    }
  }

  disconnect() {
    this._clearTimeout()
    if (this.popover) {
      this.popover.removeEventListener("mouseenter", this.onPopoverEnter)
      this.popover.removeEventListener("mouseleave", this.onPopoverLeave)
    }
    this._returnPopoverHome()
  }

  show() {
    this._clearTimeout()
    this.element.classList.add("is-open")
    this._detachPopoverToBody()
  }

  scheduleHide() {
    this._clearTimeout()
    this.hideTimeout = setTimeout(() => this._closeImmediately(), this.delay)
  }

  _closeImmediately() {
    this.element.classList.remove("is-open")
    this._returnPopoverHome()
  }

  _clearTimeout() {
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout)
      this.hideTimeout = null
    }
  }

  _detachPopoverToBody() {
    if (!this.popover || this.popover.parentNode === document.body) return

    this.homeParent = this.popover.parentNode
    this.homeNextSibling = this.popover.nextSibling

    document.body.appendChild(this.popover)
    this.popover.style.display = "block"
    this._positionPopover()

    window.addEventListener("scroll", this.onScroll, { capture: true, passive: true })
    window.addEventListener("resize", this.onScroll)
  }

  // Closes on scroll, so it has to fit the viewport: shift left, flip above.
  _positionPopover() {
    const gap = 6
    const edge = 8
    const alignRight = this.element.closest(".topic-participants") !== null
    const rect = this.element.getBoundingClientRect()

    this.popover.style.position = "fixed"
    this.popover.style.top = `${rect.bottom + gap}px`

    if (alignRight) {
      this.popover.style.left = "auto"
      this.popover.style.right = `${window.innerWidth - rect.right}px`
    } else {
      this.popover.style.left = "0px"
      this.popover.style.right = "auto"
      const maxLeft = window.innerWidth - edge - this.popover.offsetWidth
      this.popover.style.left = `${Math.max(edge, Math.min(rect.left, maxLeft))}px`
    }

    const height = this.popover.offsetHeight
    const fitsBelow = rect.bottom + gap + height <= window.innerHeight - edge
    const fitsAbove = rect.top - gap - height >= edge
    if (!fitsBelow && fitsAbove) {
      this.popover.style.top = `${rect.top - gap - height}px`
    }
  }

  _returnPopoverHome() {
    if (!this.popover || !this.homeParent) return

    window.removeEventListener("scroll", this.onScroll, { capture: true })
    window.removeEventListener("resize", this.onScroll)

    this.popover.style.display = ""
    this.popover.style.position = ""
    this.popover.style.top = ""
    this.popover.style.left = ""
    this.popover.style.right = ""

    this.homeParent.insertBefore(this.popover, this.homeNextSibling)
    this.homeParent = null
    this.homeNextSibling = null
  }
}
