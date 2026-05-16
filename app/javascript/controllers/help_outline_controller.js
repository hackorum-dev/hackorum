import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["link"]

  connect() {
    this.observer = new IntersectionObserver(
      this.onIntersect.bind(this),
      {
        rootMargin: "0px 0px -90% 0px",
        threshold: 0
      }
    )

    this.headings().forEach(heading => this.observer.observe(heading))
  }

  disconnect() {
    this.observer.disconnect()
  }

  onIntersect(entries) {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        this.setActive(entry.target.id)
      }
    })
  }

  setActive(id) {
    this.linkTargets.forEach(link => {
      link.classList.toggle(
        "active",
        link.getAttribute("href") === `#${id}`
      )
    })
  }

  headings() {
    return Array.from(
      document.querySelectorAll(".help-content h1, .help-content h2, .help-content h3")
    )
  }
}
