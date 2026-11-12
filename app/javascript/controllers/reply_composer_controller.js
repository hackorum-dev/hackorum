import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values  = { draftId: Number, autoscroll: Boolean }
  static targets = ["form", "status", "body", "version", "conflict", "conflictText"]

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
    this.unsaved = true
    if (this.hasStatusTarget) this.statusTarget.textContent = "Editing…"
    clearTimeout(this.dirtyTimer)
    this.dirtyTimer = setTimeout(() => this.save(), 2000)
  }

  save() {
    this.saving = this.store()
    return this.saving
  }

  async store() {
    clearTimeout(this.dirtyTimer)
    this.unsaved = false
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
      if (res.status === 204) {
        const version = res.headers.get("X-Draft-Version")
        if (version && this.hasVersionTarget) this.versionTarget.dataset.version = version
        if (this.hasStatusTarget) this.statusTarget.textContent = "Saved"
        return true
      }
      this.unsaved = true
      if (!this.hasStatusTarget) return false
      if (res.status === 409) {
        this.statusTarget.textContent = "Sending… (read-only)"
        this.disableForm()
      } else {
        this.statusTarget.textContent = "Save failed"
      }
    } catch (e) {
      this.unsaved = true
      if (this.hasStatusTarget) this.statusTarget.textContent = "Save failed"
    }
    return false
  }

  disableForm() {
    const scopes = [this.formTarget, ...this.element.querySelectorAll(".composer-attachments")]
    scopes.forEach(scope => {
      scope.querySelectorAll("input, textarea, button").forEach(el => {
        el.disabled = true
      })
    })
  }

  async openConfirm(event) {
    event.preventDefault()
    await this.saving
    if (this.unsaved && !(await this.save())) return
    const version = this.hasVersionTarget ? this.versionTarget.dataset.version : ""
    const url = `/drafts/${this.draftIdValue}/confirm?version=${encodeURIComponent(version)}`
    try {
      const res = await fetch(url, { headers: { Accept: "text/html" } })
      const body = await res.text()
      if (res.status === 409) {
        this.showConflict(body)
        return
      }
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

  conflict(event) {
    this.showConflict(event.detail.message)
  }

  showConflict(text) {
    if (!this.hasConflictTarget) return alert(`Cannot send: ${text}`)
    this.conflictTextTarget.textContent = text
    this.conflictTarget.hidden = false
  }

  reload() {
    const frame = this.element.closest("turbo-frame")
    if (!frame) return
    const url = `/drafts/${this.draftIdValue}/edit`
    if (frame.getAttribute("src") === url) {
      frame.reload()
    } else {
      frame.src = url
    }
  }
}
