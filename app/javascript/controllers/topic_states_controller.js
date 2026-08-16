import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { all } from "controllers/visited_topics"

const STALE_ATTRIBUTE = "data-topic-states-stale"

export default class extends Controller {
  static values = { url: String }

  initialize() {
    this.markStale = () => this.element.setAttribute(STALE_ATTRIBUTE, "")
  }

  connect() {
    document.addEventListener("turbo:before-cache", this.markStale)
    this.refresh()
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.markStale)
  }

  async refresh() {
    if (document.documentElement.hasAttribute("data-turbo-preview")) return
    if (!this.element.hasAttribute(STALE_ATTRIBUTE)) return
    this.element.removeAttribute(STALE_ATTRIBUTE)

    const ids = this.visibleVisitedIds()
    if (ids.length === 0) return

    const url = new URL(this.urlValue, window.location.origin)
    ids.forEach(id => url.searchParams.append("topic_ids[]", id))

    try {
      const response = await fetch(url, {
        headers: { Accept: "text/vnd.turbo-stream.html" }
      })
      const contentType = response.headers.get("Content-Type") || ""
      if (!response.ok || !contentType.includes("turbo-stream")) return
      Turbo.renderStreamMessage(await response.text())
    } catch (e) {
      console.warn("topic state refresh failed", e)
    }
  }

  visibleVisitedIds() {
    const visited = new Set(all())
    if (visited.size === 0) return []

    return Array.from(this.element.querySelectorAll("[data-topic-id]"))
      .map(row => parseInt(row.dataset.topicId, 10))
      .filter(id => visited.has(id))
  }
}
