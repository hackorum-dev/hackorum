import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["name", "position", "prev", "next"]
  static values = { messages: Object, timeline: String }

  connect() {
    this.element.hidden = true
    document.body.classList.remove("is-person-stepping")
    document.querySelectorAll(".message-card.is-stepping").forEach((el) => el.classList.remove("is-stepping"))
    this.observer = new ResizeObserver(() => {
      if (!this.element.hidden) document.body.style.setProperty("--person-nav-height", `${this.element.offsetHeight}px`)
    })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
  }

  start({ detail: { personId, name } }) {
    this.stop()
    this.personId = String(personId)
    this.entries = this.messagesValue[this.personId] || []
    if (this.entries.length === 0) return

    this.nameTarget.textContent = ` ${name}`
    this.element.hidden = false
    document.body.classList.add("is-person-stepping")
    this.tint(true)
    this.go(this.nearestIndex())
  }

  prev() { this.go(this.index - 1) }
  next() { this.go(this.index + 1) }

  list() {
    window.dispatchEvent(new CustomEvent("timeline-modal:open", { detail: { src: `${this.timelineValue}?person=${this.personId}` } }))
  }

  stop() {
    if (this.personId) this.tint(false)
    this.element.hidden = true
    document.body.classList.remove("is-person-stepping")
    this.personId = null
  }

  go(i) {
    this.index = Math.max(0, Math.min(i, this.entries.length - 1))
    const [id] = this.entries[this.index]
    document.getElementById(`message-${id}`)?.scrollIntoView({ block: "start" })
    history.replaceState(history.state, "", `#message-${id}`)
    this.render()
  }

  render() {
    const total = this.entries.length
    this.positionTarget.textContent = `${this.index + 1} of ${total}`
    const prev = this.entries[this.index - 1]
    const next = this.entries[this.index + 1]
    this.prevTarget.disabled = !prev
    this.nextTarget.disabled = !next
    this.prevTarget.textContent = prev ? `‹ #${prev[1]}` : "‹"
    this.nextTarget.textContent = next ? `#${next[1]} ›` : "›"
  }

  nearestIndex() {
    const offset = this.element.getBoundingClientRect().bottom
    const i = this.entries.findIndex(([id]) => {
      const el = document.getElementById(`message-${id}`)
      return el && el.getBoundingClientRect().top >= offset - 1
    })
    return i === -1 ? this.entries.length - 1 : i
  }

  tint(on) {
    document.querySelectorAll(`.message-card[data-person-id="${this.personId}"]`)
      .forEach((el) => el.classList.toggle("is-stepping", on))
  }
}
