import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "frame"]
  static values = { src: String }

  open(event) {
    event?.preventDefault()
    if (this.hasFrameTarget) this.load(this.srcValue)
    this.dialogTarget.showModal()
  }

  openSrc(event) {
    const src = event.detail?.src
    if (!src) return
    this.load(src)
    if (!this.dialogTarget.open) this.dialogTarget.showModal()
  }

  load(src) {
    if (new URL(src, location.href).href !== this.frameTarget.src) this.frameTarget.setAttribute("src", src)
  }

  close() {
    this.dialogTarget.close()
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  jump(event) {
    if (event.target.closest("a[href*='#message-']")) this.close()
  }
}
