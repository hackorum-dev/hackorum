import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["chapter", "chapterButton", "bar", "row", "commit", "day", "person", "peopleItem", "filterButton", "title", "subtitle", "prevButton", "nextButton", "empty", "noPeople", "wholeButton"]
  static values = { chapter: Number, whole: Boolean, filter: { type: String, default: "all" } }

  connect() {
    this.apply()
    this.revealSelected()
  }

  selectChapter({ params: { index } }) {
    this.chapterValue = index
    this.wholeValue = false
    this.resetFilters()
    this.apply()
  }

  selectWhole() {
    this.wholeValue = true
    this.resetFilters()
    this.apply()
  }

  prev() {
    if (this.chapterValue > 0) this.chapterValue--
    this.apply()
  }

  next() {
    if (this.chapterValue < this.chapterTargets.length - 1) this.chapterValue++
    this.apply()
  }

  setFilter({ params: { filter } }) {
    this.filterValue = filter
    this.apply()
  }

  allPeople() {
    this.personTargets.forEach((c) => { c.checked = true })
    this.apply()
  }

  noPeople() {
    this.personTargets.forEach((c) => { c.checked = false })
    this.apply()
  }

  only({ currentTarget }) {
    const box = currentTarget.closest("li").querySelector("input[type=checkbox]")
    this.personTargets.forEach((c) => { c.checked = c === box })
    this.apply()
  }

  filterPeople(event) {
    const q = event.target.value.trim().toLowerCase()
    this.peopleItemTargets.forEach((li) => { li.hidden = q !== "" && !li.dataset.name.includes(q) })
  }

  resetFilters() {
    this.filterValue = "all"
    this.personTargets.forEach((c) => { c.checked = true })
  }

  get narrowed() {
    return this.filterValue !== "all" || this.personTargets.some((c) => !c.checked)
  }

  apply() {
    const people = new Set(this.personTargets.filter((c) => c.checked).map((c) => c.value))
    const narrowed = this.narrowed
    const personNarrowed = this.personTargets.some((c) => !c.checked)
    const chaptered = this.chapterTargets.length > 1
    const whole = this.wholeValue && chaptered
    const spread = narrowed || whole

    this.rowTargets.forEach((row) => {
      row.hidden = (personNarrowed && !people.has(row.dataset.person)) || !this.matches(row)
    })
    this.commitTargets.forEach((c) => { c.hidden = narrowed })
    this.dayTargets.forEach((day) => {
      const shown = day.querySelector("[data-timeline-target='row']:not([hidden]), [data-timeline-target='commit']:not([hidden])")
      day.hidden = !shown
      if (narrowed && shown && day.tagName === "DETAILS") day.open = true
    })
    let any = false
    this.chapterTargets.forEach((section, i) => {
      const visible = section.querySelector("[data-timeline-target='day']:not([hidden])")
      section.hidden = narrowed ? !visible : (!whole && chaptered && i !== this.chapterValue)
      if (!section.hidden) any = true
    })
    const none = people.size === 0
    if (this.hasEmptyTarget) this.emptyTarget.hidden = any || none
    if (this.hasNoPeopleTarget) this.noPeopleTarget.hidden = !none

    this.chapterButtonTargets.forEach((b, i) => b.classList.toggle("is-active", !spread && i === this.chapterValue))
    this.barTargets.forEach((bar) => {
      const ids = bar.dataset.chapters ? bar.dataset.chapters.split(" ").map(Number) : []
      bar.classList.toggle("is-active", !spread && ids.includes(this.chapterValue))
    })
    this.wholeButtonTargets.forEach((b) => b.classList.toggle("is-active", whole))
    this.filterButtonTargets.forEach((b) => b.classList.toggle("is-active", b.dataset.timelineFilterParam === this.filterValue))
    if (this.hasPrevButtonTarget) this.prevButtonTarget.disabled = spread || this.chapterValue <= 0
    if (this.hasNextButtonTarget) this.nextButtonTarget.disabled = spread || this.chapterValue >= this.chapterTargets.length - 1
    if (this.hasTitleTarget) {
      const button = this.chapterButtonTargets[this.chapterValue]
      const shown = this.rowTargets.filter((r) => !r.hidden).length
      this.titleTarget.textContent = narrowed ? "All chapters, filtered" : (whole ? "Whole thread" : (button?.dataset.label || ""))
      if (this.hasSubtitleTarget) {
        this.subtitleTarget.textContent = narrowed ? `${shown} matching` : whole ? `${shown} messages` : `Chapter ${this.chapterValue + 1} of ${this.chapterTargets.length} · ${button?.dataset.meta || ""}`
      }
    }
    this.element.classList.toggle("is-narrowed", spread)
  }

  revealSelected() {
    const button = this.chapterButtonTargets[this.chapterValue]
    button?.scrollIntoView({ block: "nearest", inline: "nearest" })
  }

  matches(row) {
    switch (this.filterValue) {
      case "patch": return row.dataset.patch === "1"
      case "unread": return row.dataset.unread === "1"
      case "noted": return row.dataset.noted === "1"
      default: return true
    }
  }
}
