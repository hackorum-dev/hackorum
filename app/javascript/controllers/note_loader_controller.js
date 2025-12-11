import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = {
    url: String
  }

  async load(event) {
    event.preventDefault()
    if (!this.hasUrlValue) return

    const response = await fetch(this.urlValue, {
      headers: { Accept: "text/vnd.turbo-stream.html" }
    })
    if (response.ok) {
      const html = await response.text()
      Turbo.renderStreamMessage(html)
    }
  }

  close(event) {
    event.preventDefault()
    const formWrapper = this.element.closest(".note-form-wrapper")
    if (formWrapper) {
      const container = formWrapper.closest(".notes-block")
      formWrapper.remove()
      if (container && container.querySelectorAll(".note-card").length === 0 && !container.querySelector(".note-form-wrapper")) {
        container.remove()
      }
      return
    }

    const details = this.element.closest("details")
    if (details && details.open) {
      details.open = false
    }
  }
}
