import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { messageId: Number }

  jump(event) {
    event.preventDefault()
    const frame = document.getElementById(`draft-${this.messageIdValue}`)
    if (!frame) return
    frame.scrollIntoView({ behavior: "smooth", block: "start" })
    const body = frame.querySelector("textarea")
    if (body) setTimeout(() => body.focus({ preventScroll: true }), 300)
  }
}
