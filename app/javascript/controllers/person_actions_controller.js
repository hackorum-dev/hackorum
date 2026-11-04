import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { personId: Number, name: String, timeline: String }

  stepThrough() {
    this.closeDialogs()
    window.dispatchEvent(new CustomEvent("person-nav:start", { detail: { personId: this.personIdValue, name: this.nameValue } }))
  }

  listAll() {
    this.closeDialogs()
    window.dispatchEvent(new CustomEvent("timeline-modal:open", { detail: { src: this.timelineValue } }))
  }

  closeDialogs() {
    document.querySelectorAll("dialog[open]").forEach((d) => d.close())
    window.dispatchEvent(new CustomEvent("sidebar:close-mobile"))
  }
}
