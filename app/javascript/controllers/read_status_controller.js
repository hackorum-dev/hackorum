import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    messageId: Number,
    readUrl: String,
    delaySeconds: Number,
  }

  connect() {
    this.marked = false
    this.timer = null
    this.pollInterval = null
    this.observe()
  }

  disconnect() {
    this.cleanup()
  }

  observe() {
    if (!("IntersectionObserver" in window)) return

    this.observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting && this.visibleEnough(entry)) {
          this.stopPoll()
          this.startTimer()
        } else if (entry.isIntersecting && this.needsPollFallback()) {
          this.startPoll()
        } else {
          this.stopPoll()
          this.clearTimer()
        }
      })
    }, { threshold: [0.1, 0.25, 0.5, 0.7, 0.9] })

    this.observer.observe(this.element)
  }

  visibleEnough(entry) {
    const visiblePx = entry.intersectionRect.height
    const elementHeight = entry.target.getBoundingClientRect().height || 1
    const ratio = visiblePx / elementHeight

    // Standard case: most of the element is on screen.
    if (ratio >= 0.7) return true

    // Very tall elements that cannot reach high ratio: accept when a good chunk is visible.
    const viewportHeight = window.innerHeight || 800
    const substantialPx = Math.min(viewportHeight * 0.8, 400) // cap to avoid excessive requirement
    if (visiblePx >= substantialPx) return true

    // Fallback: modest ratio plus reasonable pixels.
    return ratio >= 0.25 && visiblePx >= 200
  }

  needsPollFallback() {
    return this.element.getBoundingClientRect().height > (window.innerHeight || 800)
  }

  startPoll() {
    if (this.marked || this.pollInterval || this.timer) return
    this.pollInterval = setInterval(() => this.checkVisibility(), 1000)
  }

  stopPoll() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval)
      this.pollInterval = null
    }
  }

  checkVisibility() {
    if (this.marked) { this.stopPoll(); return }

    const rect = this.element.getBoundingClientRect()
    const viewportHeight = window.innerHeight || 800
    const visibleTop = Math.max(0, rect.top)
    const visibleBottom = Math.min(viewportHeight, rect.bottom)
    const visiblePx = Math.max(0, visibleBottom - visibleTop)

    if (visiblePx <= 0) {
      this.stopPoll()
      this.clearTimer()
      return
    }

    const substantialPx = Math.min(viewportHeight * 0.8, 400)
    if (visiblePx >= substantialPx) {
      this.stopPoll()
      this.startTimer()
    }
  }

  startTimer() {
    if (this.marked || this.timer) return
    const delay = (this.delaySecondsValue || 5) * 1000
    this.timer = setTimeout(() => this.markRead(), delay)
  }

  clearTimer() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }

  cleanup() {
    this.clearTimer()
    this.stopPoll()
    if (this.observer) {
      this.observer.disconnect()
      this.observer = null
    }
  }

  async markRead() {
    if (this.marked) return
    this.marked = true
    this.element.classList.add("is-read")

    try {
      await fetch(this.readUrlValue, {
        method: "POST",
        headers: this.csrfHeaders(),
      })
    } catch (e) {
      // If it fails, we leave the optimistic state; we could retry if needed.
      console.warn("mark read failed", e)
    }
  }

  csrfHeaders() {
    const token = document.querySelector("meta[name=csrf-token]")?.content
    return token ? { "X-CSRF-Token": token } : {}
  }
}
