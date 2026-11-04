import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item"]

  filter(event) {
    const q = event.target.value.trim().toLowerCase()
    this.itemTargets.forEach((el) => { el.hidden = q !== "" && !el.dataset.name.includes(q) })
  }
}
