import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values  = { draftId: Number, autoscroll: Boolean }
  static targets = ["form", "status", "body"]

  connect() {
    this.dirtyTimer = null
    if (this.hasStatusTarget) this.statusTarget.textContent = "Saved"
    if (this.autoscrollValue) {
      requestAnimationFrame(() => {
        this.element.scrollIntoView({ behavior: "smooth", block: "start" })
      })
    }
  }

  disconnect() {
    clearTimeout(this.dirtyTimer)
  }

  dirty() {
    if (this.hasStatusTarget) this.statusTarget.textContent = "Editing…"
    clearTimeout(this.dirtyTimer)
    this.dirtyTimer = setTimeout(() => this.save(), 2000)
  }

  async save() {
    clearTimeout(this.dirtyTimer)
    if (this.hasStatusTarget) this.statusTarget.textContent = "Saving…"

    const formData = new FormData(this.formTarget)
    const csrfMeta = document.querySelector('meta[name="csrf-token"]')
    const headers = {
      "Accept": "application/json"
    }
    if (csrfMeta) headers["X-CSRF-Token"] = csrfMeta.content

    try {
      const res = await fetch(this.formTarget.action, {
        method: "PATCH",
        body: formData,
        headers
      })
      if (!this.hasStatusTarget) return
      if (res.status === 204) {
        this.statusTarget.textContent = "Saved"
      } else if (res.status === 409) {
        this.statusTarget.textContent = "Sending… (read-only)"
        this.disableForm()
      } else {
        this.statusTarget.textContent = "Save failed"
      }
    } catch (e) {
      if (this.hasStatusTarget) this.statusTarget.textContent = "Save failed"
    }
  }

  disableForm() {
    this.formTarget.querySelectorAll("input, textarea, button").forEach(el => {
      el.disabled = true
    })
  }

  async openConfirm(event) {
    event.preventDefault()
    const url = `/drafts/${this.draftIdValue}/confirm`
    try {
      const res = await fetch(url, { headers: { Accept: "text/html" } })
      const body = await res.text()
      if (!res.ok) {
        alert(`Cannot send: ${body || res.statusText}`)
        return
      }
      const frame = document.getElementById(`confirm-${this.draftIdValue}`)
      if (frame) {
        frame.innerHTML = body
      }
    } catch (e) {
      alert(`Cannot send: ${e.message}`)
    }
  }
}
