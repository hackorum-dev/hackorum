import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "hackorum-density"
const DEFAULT_DENSITY = "default"
const VALID_DENSITIES = ["tiny", "compact", "default", "comfortable", "spacious"]

export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.applyInitialDensity()
  }

  select(event) {
    event.preventDefault()
    const { densityValue } = event.currentTarget.dataset
    this.setDensity(densityValue)
  }

  applyInitialDensity() {
    const stored = window.localStorage.getItem(STORAGE_KEY)
    const initial = VALID_DENSITIES.includes(stored) ? stored : DEFAULT_DENSITY
    this.setDensity(initial, { persist: false })
  }

  setDensity(density, { persist = true } = {}) {
    const normalized = VALID_DENSITIES.includes(density) ? density : DEFAULT_DENSITY
    document.documentElement.dataset.density = normalized

    if (persist) {
      window.localStorage.setItem(STORAGE_KEY, normalized)
    }

    this.updateButtons(normalized)
  }

  updateButtons(density) {
    if (this.hasButtonTarget) {
      this.buttonTargets.forEach((button) => {
        button.classList.toggle("is-active", button.dataset.densityValue === density)
      })
    }
  }

  get currentDensity() {
    return document.documentElement.dataset.density || DEFAULT_DENSITY
  }
}
