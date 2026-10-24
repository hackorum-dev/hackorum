import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    url: String,
    batchSize: { type: Number, default: 50 },
    signedIn: { type: Boolean, default: false }
  }

  static targets = ["skeleton"]

  connect() {
    this.abortController = new AbortController()
    this.loadAllBatches()
  }

  disconnect() {
    this.abortController?.abort()
  }

  async loadAllBatches() {
    const skeletons = this.skeletonTargets
    if (skeletons.length === 0) return
    // a reconnect replaces abortController, this loop keeps its own
    const signal = this.abortController.signal

    const allIds = skeletons.map(el => {
      return el.closest(".message-card").dataset.messageId
    })

    for (let i = 0; i < allIds.length; i += this.batchSizeValue) {
      if (signal.aborted) return
      const batchIds = allIds.slice(i, i + this.batchSizeValue)
      await this.fetchAndInjectBatch(batchIds, signal)
    }
  }

  async fetchAndInjectBatch(ids, signal) {
    const url = `${this.urlValue}?ids=${ids.join(",")}`
    try {
      const response = await fetch(url, { signal })
      if (!response.ok) return
      const html = await response.text()
      this.injectBatch(html)
    } catch (e) {
      if (e.name === "AbortError") return
      console.warn("batch load failed", e)
    }
  }

  findScrollAnchor() {
    if (window.location.hash) {
      const el = document.getElementById(window.location.hash.slice(1))
      if (el) return el
    }
    for (const card of this.element.querySelectorAll('.message-card')) {
      const rect = card.getBoundingClientRect()
      if (rect.bottom > 0 && rect.top < window.innerHeight) return card
    }
    return null
  }

  injectBatch(html) {
    const template = document.createElement("template")
    template.innerHTML = html

    const anchor = this.findScrollAnchor()
    const anchorTop = anchor ? anchor.getBoundingClientRect().top : null

    template.content.querySelectorAll("[data-message-id]").forEach(batchItem => {
      const messageId = batchItem.dataset.messageId
      const card = this.element.querySelector(
        `.message-card[data-message-id="${messageId}"]`
      )
      if (!card) return

      const skeleton = card.querySelector(".message-batch-skeleton")
      if (!skeleton) return // already rendered inline, skip

      const isRead = card.dataset.read === "true"

      // The batchItem contains a div[data-message-id] wrapping .message-content
      // Extract the .message-content element
      const content = batchItem.firstElementChild
      if (!content) return

      if (isRead) {
        content.classList.add("is-read")
      }

      skeleton.replaceWith(content)

      if (this.signedInValue) {
        const messageContent = card.querySelector(".message-content")
        if (messageContent) {
          messageContent.dataset.controller = "read-status"
          messageContent.dataset.readStatusMessageIdValue = messageId
          messageContent.dataset.readStatusReadUrlValue = `/messages/${messageId}/read.json`
          messageContent.dataset.readStatusDelaySecondsValue = "5"
        }
      }
    })

    if (anchor && anchorTop !== null) {
      const drift = anchor.getBoundingClientRect().top - anchorTop
      if (Math.abs(drift) > 1) {
        window.scrollBy(0, drift)
      }
    }
  }
}
