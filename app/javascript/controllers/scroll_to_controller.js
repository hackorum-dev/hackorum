import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { target: String }

  scroll(event) {
    const el = document.querySelector(this.targetValue)
    if (!el) return
    if (event) event.preventDefault()
    el.scrollIntoView({ behavior: "smooth", block: "start" })
  }
}
