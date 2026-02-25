import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    url: String,
    intervalMs: { type: Number, default: 180000 },
  }

  connect() {
    this.startPolling()
  }

  disconnect() {
    this.stopPolling()
  }

  startPolling() {
    this.poller = setInterval(() => this.fetchBanner(), this.intervalMsValue)
  }

  stopPolling() {
    if (this.poller) {
      clearInterval(this.poller)
      this.poller = null
    }
  }

  fetchBanner() {
    if (!this.urlValue) return

    fetch(this.urlValue, { headers: { "Accept": "text/html" } })
      .then(response => response.ok ? response.text() : Promise.reject(response))
      .then(html => {
        this.element.innerHTML = html
      })
      .catch(error => {
        console.warn("Failed to refresh new topics banner", error)
      })
  }
}
