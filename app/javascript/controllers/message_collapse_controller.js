import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { collapsed: Boolean }

  connect() {
    this.applyState()
  }

  collapsedValueChanged() {
    this.applyState()
  }

  toggle() {
    this.collapsedValue = !this.collapsedValue
  }

  headerClick(event) {
    if (event.target.closest("a, button")) return
    this.toggle()
  }

  applyState() {
    this.element.classList.toggle("is-collapsed", this.collapsedValue)
    const icon = this.element.querySelector(".message-collapse-toggle i")
    if (icon) {
      icon.classList.toggle("fa-chevron-down", this.collapsedValue)
      icon.classList.toggle("fa-chevron-up", !this.collapsedValue)
    }
  }
}
