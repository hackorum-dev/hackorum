import { Controller } from "@hotwired/stimulus"

// Adds a small delay before hiding popovers so users can move the cursor into them.
export default class extends Controller {
  static targets = ["popover"]
  static values = { delay: Number }

  connect() {
    this.hideTimeout = null
    this.delay = this.delayValue || 150
  }

  show() {
    this._clearTimeout()
    this.element.classList.add("is-open")
  }

  scheduleHide() {
    this._clearTimeout()
    this.hideTimeout = setTimeout(() => {
      this.element.classList.remove("is-open")
    }, this.delay)
  }

  _clearTimeout() {
    if (this.hideTimeout) {
      clearTimeout(this.hideTimeout)
      this.hideTimeout = null
    }
  }
}
