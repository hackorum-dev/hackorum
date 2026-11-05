import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values  = { url: String, remaining: Number }
  static targets = ["input", "error"]

  async upload() {
    const files = Array.from(this.inputTarget.files)
    if (files.length === 0) return

    const picked = files.reduce((sum, f) => sum + f.size, 0)
    if (picked > this.remainingValue) {
      this.showError(`Too large: ${this.mb(picked)} picked, ${this.mb(this.remainingValue)} left`)
      this.inputTarget.value = ""
      return
    }

    const formData = new FormData()
    files.forEach(f => formData.append("files[]", f))
    const headers = { "Accept": "text/vnd.turbo-stream.html" }
    const csrfMeta = document.querySelector('meta[name="csrf-token"]')
    if (csrfMeta) headers["X-CSRF-Token"] = csrfMeta.content

    this.inputTarget.disabled = true
    try {
      const res = await fetch(this.urlValue, { method: "POST", body: formData, headers })
      const type = res.headers.get("Content-Type") || ""
      if (type.includes("turbo-stream")) {
        Turbo.renderStreamMessage(await res.text())
      } else {
        this.showError("Upload failed")
      }
    } catch (e) {
      this.showError("Upload failed")
    } finally {
      this.inputTarget.value = ""
      this.inputTarget.disabled = false
    }
  }

  mb(bytes) {
    return `${Math.round(bytes / 1048576 * 10) / 10} MB`
  }

  showError(text) {
    if (this.hasErrorTarget) this.errorTarget.textContent = text
  }
}
