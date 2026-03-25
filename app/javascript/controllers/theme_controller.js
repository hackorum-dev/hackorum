import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "hackorum-theme"
const DEFAULT_THEME = "light"

export default class extends Controller {
  static targets = ["icon", "label", "button"]

  connect() {
    this.applyInitialTheme()
  }

  toggle(event) {
    if (event && event.type !== "change") {
      event.preventDefault()
    }
    const nextTheme = this.currentTheme === "dark" ? "light" : "dark"
    this.setTheme(nextTheme)
  }

  select(event) {
    event.preventDefault()
    const { themeValue } = event.currentTarget.dataset
    this.setTheme(themeValue)
  }

  applyInitialTheme() {
    const storedTheme = window.localStorage.getItem(STORAGE_KEY)
    const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches
    const initialTheme = storedTheme || (prefersDark ? "dark" : DEFAULT_THEME)

    this.setTheme(initialTheme, { persist: false })
  }

  setTheme(theme, { persist = true } = {}) {
    const normalizedTheme = theme === "dark" ? "dark" : "light"
    document.documentElement.dataset.theme = normalizedTheme

    if (persist) {
      window.localStorage.setItem(STORAGE_KEY, normalizedTheme)
    }

    this.updateToggle(normalizedTheme)
  }

  updateToggle(theme) {
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = theme === "dark" ? "Dark" : "Light"
    }

    if (this.hasIconTarget) {
      this.iconTarget.classList.remove("fa-regular", "fa-solid", "fa-moon", "fa-sun")
      this.iconTarget.classList.add("fa-solid")
      this.iconTarget.classList.add(theme === "dark" ? "fa-sun" : "fa-moon")
    }

    this.element.setAttribute("aria-pressed", theme === "dark")
    this.element.setAttribute("aria-label", `Switch to ${theme === "dark" ? "light" : "dark"} mode`)
    this.element.setAttribute("title", `Switch to ${theme === "dark" ? "light" : "dark"} mode`)

    if (this.hasButtonTarget) {
      this.buttonTargets.forEach((button) => {
        button.classList.toggle("is-active", button.dataset.themeValue === theme)
      })
    }
  }

  get currentTheme() {
    return document.documentElement.dataset.theme || DEFAULT_THEME
  }
}
