import { Controller } from "@hotwired/stimulus"
import { remember } from "controllers/visited_topics"

export default class extends Controller {
  static values = { id: Number }

  connect() {
    remember(this.idValue)
  }
}
