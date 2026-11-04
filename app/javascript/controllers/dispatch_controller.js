import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { event: String, detail: Object }

  fire() {
    window.dispatchEvent(new CustomEvent(this.eventValue, { detail: this.detailValue }))
  }
}
