import { Controller } from "@hotwired/stimulus"

const STORAGE_WIDTH_KEY = "hackorum-sidebar-width"
const STORAGE_COLLAPSED_KEY = "hackorum-sidebar-collapsed"
const DEFAULT_WIDTH = 360
const MIN_WIDTH = 260
const MAX_WIDTH = 960
const MAX_WIDTH_RATIO = 0.75

export default class extends Controller {
  static targets = ["layout", "sidebar", "resizer", "toggleButton", "toggleIcon"]

  connect() {
    if (!this.hasLayoutTarget || !this.hasSidebarTarget) {
      return
    }

    this.handleWindowResize = this.handleWindowResize.bind(this)
    window.addEventListener("resize", this.handleWindowResize)

    this.applyStoredState()
  }

  disconnect() {
    window.removeEventListener("resize", this.handleWindowResize)
    this.stopResize()
  }

  toggle() {
    if (this.isCollapsed()) {
      this.expand()
    } else {
      this.collapse()
    }
  }

  startResize(event) {
    if (this.isCollapsed()) {
      return
    }

    event.preventDefault()
    this.isResizing = true
    this.startX = this.clientXFrom(event)
    this.startWidth = this.sidebarTarget.getBoundingClientRect().width

    this.boundHandleResize = this.handleResize.bind(this)
    this.boundStopResize = this.stopResize.bind(this)

    document.addEventListener("mousemove", this.boundHandleResize)
    document.addEventListener("mouseup", this.boundStopResize)
    document.addEventListener("touchmove", this.boundHandleResize, { passive: false })
    document.addEventListener("touchend", this.boundStopResize)

    document.body.classList.add("sidebar-resizing")
  }

  handleResize(event) {
    if (!this.isResizing) {
      return
    }

    event.preventDefault()
    const delta = this.clientXFrom(event) - this.startX
    const nextWidth = this.clampWidth(this.startWidth + delta)
    this.setSidebarWidth(nextWidth)
  }

  stopResize() {
    if (!this.isResizing) {
      return
    }

    this.isResizing = false
    document.body.classList.remove("sidebar-resizing")

    document.removeEventListener("mousemove", this.boundHandleResize)
    document.removeEventListener("mouseup", this.boundStopResize)
    document.removeEventListener("touchmove", this.boundHandleResize)
    document.removeEventListener("touchend", this.boundStopResize)

    window.localStorage.setItem(STORAGE_WIDTH_KEY, String(this.currentWidth || this.startWidth || DEFAULT_WIDTH))
  }

  handleWindowResize() {
    if (this.isCollapsed()) {
      return
    }

    const stored = this.readWidth()
    this.setSidebarWidth(this.clampWidth(stored))
  }

  applyStoredState() {
    const collapsed = window.localStorage.getItem(STORAGE_COLLAPSED_KEY) === "true"
    if (collapsed) {
      this.collapse(false)
      return
    }

    this.expand(false)
    this.setSidebarWidth(this.clampWidth(this.readWidth()))
  }

  collapse(shouldStore = true) {
    document.body.classList.add("sidebar-collapsed")
    if (shouldStore) {
      window.localStorage.setItem(STORAGE_COLLAPSED_KEY, "true")
    }
    this.updateToggleIcon()
  }

  expand(shouldStore = true) {
    document.body.classList.remove("sidebar-collapsed")
    if (shouldStore) {
      window.localStorage.setItem(STORAGE_COLLAPSED_KEY, "false")
    }
    this.setSidebarWidth(this.clampWidth(this.readWidth()))
    this.updateToggleIcon()
  }

  updateToggleIcon() {
    if (!this.hasToggleIconTarget) {
      return
    }

    this.toggleIconTarget.textContent = this.isCollapsed() ? "▶" : "◀"
  }

  isCollapsed() {
    return document.body.classList.contains("sidebar-collapsed")
  }

  readWidth() {
    const stored = Number.parseFloat(window.localStorage.getItem(STORAGE_WIDTH_KEY))
    if (Number.isFinite(stored) && stored > 0) {
      return stored
    }
    return DEFAULT_WIDTH
  }

  setSidebarWidth(width) {
    this.currentWidth = width
    this.layoutTarget.style.setProperty("--sidebar-width", `${width}px`)
  }

  clampWidth(width) {
    const maxWidth = Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, Math.round(window.innerWidth * MAX_WIDTH_RATIO)))
    return Math.min(Math.max(width, MIN_WIDTH), maxWidth)
  }

  clientXFrom(event) {
    if (event.touches && event.touches.length > 0) {
      return event.touches[0].clientX
    }
    if (event.changedTouches && event.changedTouches.length > 0) {
      return event.changedTouches[0].clientX
    }
    return event.clientX
  }
}
