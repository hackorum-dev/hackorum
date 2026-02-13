import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    if (this.element.dataset.diffHighlighted === "true") return

    const text = this.element.textContent
    if (!text) return

    const fragment = document.createDocumentFragment()
    const lines = text.split("\n")

    lines.forEach((line) => {
      const span = document.createElement("span")
      span.classList.add("diff-line")

      if (line.startsWith("+") && !line.startsWith("+++")) {
        span.classList.add("diff-line-add")
      } else if (line.startsWith("-") && !line.startsWith("---")) {
        span.classList.add("diff-line-del")
      } else if (line.startsWith("@@")) {
        span.classList.add("diff-line-hunk")
      } else if (
        line.startsWith("diff ") ||
        line.startsWith("index ") ||
        line.startsWith("---") ||
        line.startsWith("+++")
      ) {
        span.classList.add("diff-line-header")
      }

      span.textContent = line.length ? line : " "
      fragment.appendChild(span)
    })

    this.element.textContent = ""
    this.element.appendChild(fragment)
    this.element.dataset.diffHighlighted = "true"
    this.element.classList.add("diff-highlighted")
  }
}
