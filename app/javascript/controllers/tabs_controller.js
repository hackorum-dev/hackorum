import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]

  select(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)

    this.tabTargets.forEach((tab, i) => {
      tab.classList.toggle("is-active", i === index)
      tab.setAttribute("aria-selected", i === index)
    })

    this.panelTargets.forEach((panel, i) => {
      panel.classList.toggle("is-active", i === index)
    })
  }
}
