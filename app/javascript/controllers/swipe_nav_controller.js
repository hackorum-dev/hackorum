import { Controller } from "@hotwired/stimulus"

const SWIPE_DISTANCE_PX = 60
const SWIPE_AXIS_RATIO = 1.2
const SWIPE_TIME_MS = 700

export default class extends Controller {
  connect() {
    this.onPointerDown = this.onPointerDown.bind(this)
    this.onPointerMove = this.onPointerMove.bind(this)
    this.onPointerUp = this.onPointerUp.bind(this)
    this.onTouchStart = this.onTouchStart.bind(this)
    this.onTouchMove = this.onTouchMove.bind(this)
    this.onTouchEnd = this.onTouchEnd.bind(this)
    window.addEventListener("pointerdown", this.onPointerDown, { passive: true })
    window.addEventListener("touchstart", this.onTouchStart, { passive: true })
  }

  disconnect() {
    window.removeEventListener("pointerdown", this.onPointerDown, { passive: true })
    window.removeEventListener("touchstart", this.onTouchStart, { passive: true })
    this.detachTrackingListeners()
    this.detachTouchTrackingListeners()
  }

  onPointerDown(event) {
    if (!event.isPrimary) return
    if (event.pointerType !== "touch" && event.pointerType !== "pen") return
    if (event.button && event.button !== 0) return
    if (this.shouldIgnoreTarget(event.target)) return

    this.usingPointer = true
    this.tracking = true
    this.pointerId = event.pointerId
    this.startX = event.clientX
    this.startY = event.clientY
    this.startTime = performance.now()
    this.lastX = event.clientX
    this.lastY = event.clientY

    window.addEventListener("pointermove", this.onPointerMove, { passive: true })
    window.addEventListener("pointerup", this.onPointerUp, { passive: true })
    window.addEventListener("pointercancel", this.onPointerUp, { passive: true })
  }

  onPointerMove(event) {
    if (!this.tracking || event.pointerId !== this.pointerId) return
    this.lastX = event.clientX
    this.lastY = event.clientY
  }

  onPointerUp(event) {
    if (!this.tracking || event.pointerId !== this.pointerId) return

    const elapsed = performance.now() - this.startTime
    const deltaX = this.lastX - this.startX
    const deltaY = this.lastY - this.startY

    this.tracking = false
    this.pointerId = null
    this.usingPointer = false
    this.detachTrackingListeners()

    this.maybeNavigate(elapsed, deltaX, deltaY)
  }

  detachTrackingListeners() {
    window.removeEventListener("pointermove", this.onPointerMove, { passive: true })
    window.removeEventListener("pointerup", this.onPointerUp, { passive: true })
    window.removeEventListener("pointercancel", this.onPointerUp, { passive: true })
  }

  onTouchStart(event) {
    if (this.usingPointer) return
    if (!event.touches || event.touches.length !== 1) return
    if (this.shouldIgnoreTarget(event.target)) return

    const touch = event.touches[0]
    this.touchTracking = true
    this.startX = touch.clientX
    this.startY = touch.clientY
    this.startTime = performance.now()
    this.lastX = touch.clientX
    this.lastY = touch.clientY

    window.addEventListener("touchmove", this.onTouchMove, { passive: true })
    window.addEventListener("touchend", this.onTouchEnd, { passive: true })
    window.addEventListener("touchcancel", this.onTouchEnd, { passive: true })
  }

  onTouchMove(event) {
    if (!this.touchTracking || !event.touches || event.touches.length !== 1) return
    const touch = event.touches[0]
    this.lastX = touch.clientX
    this.lastY = touch.clientY
  }

  onTouchEnd() {
    if (!this.touchTracking) return

    const elapsed = performance.now() - this.startTime
    const deltaX = this.lastX - this.startX
    const deltaY = this.lastY - this.startY

    this.touchTracking = false
    this.detachTouchTrackingListeners()

    this.maybeNavigate(elapsed, deltaX, deltaY)
  }

  detachTouchTrackingListeners() {
    window.removeEventListener("touchmove", this.onTouchMove, { passive: true })
    window.removeEventListener("touchend", this.onTouchEnd, { passive: true })
    window.removeEventListener("touchcancel", this.onTouchEnd, { passive: true })
  }

  maybeNavigate(elapsed, deltaX, deltaY) {
    if (elapsed > SWIPE_TIME_MS) return
    if (Math.abs(deltaX) < SWIPE_DISTANCE_PX) return
    if (Math.abs(deltaX) < Math.abs(deltaY) * SWIPE_AXIS_RATIO) return

    if (deltaX > 0) {
      window.history.back()
    } else {
      window.history.forward()
    }
  }

  shouldIgnoreTarget(target) {
    if (!target) return true
    if (target.closest("input, textarea, select, [contenteditable='true']")) return true
    if (this.isInHorizontalScrollableArea(target)) return true
    return false
  }

  isInHorizontalScrollableArea(target) {
    let el = target
    while (el && el !== document.body) {
      const style = window.getComputedStyle(el)
      const overflowX = style.overflowX
      if ((overflowX === "auto" || overflowX === "scroll" || overflowX === "overlay") &&
          el.scrollWidth > el.clientWidth + 1) {
        return true
      }
      el = el.parentElement
    }
    return false
  }
}
