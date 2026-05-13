import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this._stored = ""
    this._onMouseUp = () => { this._stored = this._selectionInBody() }
    this.element.addEventListener("mouseup", this._onMouseUp)
  }

  disconnect() {
    this.element.removeEventListener("mouseup", this._onMouseUp)
  }

  injectSelection(event) {
    const text = this._stored || this._selectionInBody()
    this._stored = ""
    if (!text) return

    const input = document.createElement("input")
    input.type = "hidden"
    input.name = "selected_text"
    input.value = text
    event.target.appendChild(input)
  }

  _selectionInBody() {
    const sel = window.getSelection()
    if (!sel || sel.isCollapsed) return ""
    const range = sel.getRangeAt(0)
    const body = this.element.querySelector(".message-body")
    return (body && body.contains(range.commonAncestorContainer))
      ? sel.toString().trim()
      : ""
  }
}
