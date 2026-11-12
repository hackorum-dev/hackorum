import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values  = { cooldown: Number }
  static targets = ["submit"]

  connect() {
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = true
      this.cooldownTimer = setTimeout(() => {
        this.submitTarget.disabled = false
      }, this.cooldownValue || 1500)
    }
    this.boundEsc = this.onEsc.bind(this)
    this.boundOutsideClick = this.onOutsideClick.bind(this)
    this.boundSubmit = this.onSubmit.bind(this)
    document.addEventListener("keydown", this.boundEsc)
    this.element.addEventListener("click", this.boundOutsideClick)
    this.element.querySelectorAll("form").forEach(f => f.addEventListener("submit", this.boundSubmit))
  }

  async onSubmit(event) {
    const form = event.target
    if (!form.action.match(/send_now/)) return  // only intercept the send form
    event.preventDefault()
    const formData = new FormData(form)
    try {
      const res = await fetch(form.action, {
        method: form.method.toUpperCase(),
        body: formData,
        headers: { Accept: "text/html" },
        redirect: "follow"
      })
      if (res.ok || res.redirected) {
        // Force a full reload. fetch already followed the redirect to the
        // topic page; setting href to the same path (only the hash changed)
        // would otherwise just update the hash and leave the composer DOM in
        // place. After reload the destroyed draft no longer renders and the
        // new pending message appears in the timeline.
        history.replaceState({}, "", res.url)
        window.location.reload()
      } else if (res.status === 409) {
        // the composer shows it, with a way to reload the draft
        this.dispatch("conflict", { detail: { message: await res.text() } })
        this.cancel()
      } else {
        const body = await res.text()
        alert(`Cannot send: ${body || res.statusText}`)
      }
    } catch (e) {
      alert(`Cannot send: ${e.message}`)
    }
  }

  disconnect() {
    clearTimeout(this.cooldownTimer)
    document.removeEventListener("keydown", this.boundEsc)
    this.element.removeEventListener("click", this.boundOutsideClick)
    this.element.querySelectorAll("form").forEach(f => f.removeEventListener("submit", this.boundSubmit))
  }

  onEsc(event) {
    if (event.key === "Escape") this.cancel(event)
  }

  onOutsideClick(event) {
    if (event.target === this.element) this.cancel(event)
  }

  cancel(event) {
    if (event) event.preventDefault()
    const frame = this.element.closest("turbo-frame")
    if (frame) frame.innerHTML = ""
  }
}
