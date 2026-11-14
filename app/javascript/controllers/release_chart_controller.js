import { Controller } from "@hotwired/stimulus"

let echarts
let echartsPromise
const loadEcharts = () => (echartsPromise ||= import("echarts").then((m) => (echarts = m)))

// kind + data from the server, option built here: ECharts tooltips are
// functions, which cannot ride in a JSON attribute. Colors come from the
// --stats-* tokens so a theme switch re-renders with the other palette.
export default class extends Controller {
  static values = { kind: String, data: Object }

  connect() {
    this.generation = 0
    this.theme = document.documentElement.dataset.theme
    this.observer = new MutationObserver(() => {
      if (this.theme === document.documentElement.dataset.theme) return
      this.theme = document.documentElement.dataset.theme
      this.render()
    })
    this.observer.observe(document.documentElement, { attributeFilter: ["data-theme"] })
    this.sizeObserver = new ResizeObserver(() => this.chart?.resize())
    this.sizeObserver.observe(this.element)
    this.render()
  }

  disconnect() {
    this.generation++
    this.observer?.disconnect()
    this.sizeObserver?.disconnect()
    if (this.pinClick) document.removeEventListener("click", this.pinClick)
    if (this.pinHover) {
      document.removeEventListener("mouseover", this.pinHover)
      document.removeEventListener("mouseout", this.pinHover)
    }
    this.pinClick = this.pinHover = null
    this.chart?.dispose()
    this.chart = null
  }

  async render() {
    const builder = BUILDERS[this.kindValue]
    if (!builder) return this.fail()
    const token = ++this.generation
    try {
      await loadEcharts()
    } catch (e) {
      if (token === this.generation) this.fail()
      return
    }
    if (token !== this.generation || !this.element.isConnected) return
    this.chart?.dispose()
    this.element.classList.remove("muted")
    this.element.textContent = ""
    this.chart = echarts.init(this.element, null, { renderer: "svg" })
    try {
      if (this.kindValue === "bump") this.initPins()
      this.chart.setOption(builder(this.dataValue, { ...palette(), pins: this.pins }, this.element))
      if (this.kindValue === "bump") this.wirePins()
      const paths = this.dataValue.paths
      if (paths) this.chart.on("click", (e) => { const url = paths[Array.isArray(e.value) ? e.value[0] : e.dataIndex]; if (url) window.Turbo ? window.Turbo.visit(url) : window.location.assign(url) })
    } catch (e) {
      this.fail()
    }
  }

  // bump: click a line, or an element with data-stats-pin, to pin a person
  wirePins() {
    this.chart.on("click", (e) => {
      const id = e.seriesId ?? this.chart.getOption().series[e.seriesIndex]?.id
      if (id != null) this.togglePin(Number(id))
    })
    // hovering a line between points: show the tip of its nearest point
    this.chart.on("mouseover", (e) => {
      if (e.componentType !== "series" || e.dataIndex != null || !e.event) return
      const values = this.chart.getOption().series[e.seriesIndex].data.map((d) => d?.value ?? d)
      const [x] = this.chart.convertFromPixel({ seriesIndex: e.seriesIndex }, [e.event.offsetX, e.event.offsetY])
      let best = -1
      values.forEach((v, j) => { if (v != null && (best < 0 || Math.abs(j - x) < Math.abs(best - x))) best = j })
      if (best >= 0) this.chart.dispatchAction({ type: "showTip", seriesIndex: e.seriesIndex, dataIndex: best })
    })
    if (!this.pinClick) {
      this.pinClick = (e) => {
        const el = e.target.closest("[data-stats-pin]")
        if (!el || e.target.closest("a")) return
        this.togglePin(Number(el.dataset.statsPin))
      }
      document.addEventListener("click", this.pinClick)
      this.pinHover = (e) => {
        const el = e.target.closest?.("[data-stats-pin]")
        if (!el || !this.chart || el.contains(e.relatedTarget)) return
        this.chart.dispatchAction({ type: e.type === "mouseover" ? "highlight" : "downplay", seriesId: el.dataset.statsPin })
      }
      document.addEventListener("mouseover", this.pinHover)
      document.addEventListener("mouseout", this.pinHover)
    }
    this.markPins()
  }

  initPins() {
    if (this.pins) return
    this.pins = Array(PIN_SLOTS).fill(null)
    const pinned = (this.dataValue.pinned || []).slice(0, PIN_SLOTS)
    pinned.forEach((id, i) => { this.pins[i] = id })
    // the defaults give way from the lowest rank up
    this.pinOrder = [...pinned].reverse()
  }

  // a new pin takes the lowest free slot, so the others keep their colors;
  // when all are taken it replaces the oldest
  togglePin(id) {
    if (!this.dataValue.lines.some((l) => l.id === id)) return
    const at = this.pins.indexOf(id)
    if (at >= 0) {
      this.pins[at] = null
      this.pinOrder = this.pinOrder.filter((x) => x !== id)
    } else {
      let slot = this.pins.indexOf(null)
      if (slot < 0) slot = this.pins.indexOf(this.pinOrder.shift())
      this.pins[slot] = id
      this.pinOrder.push(id)
    }
    this.chart.setOption(BUILDERS.bump(this.dataValue, { ...palette(), pins: this.pins }), { notMerge: true })
    this.markPins()
  }

  markPins() {
    const p = palette()
    document.querySelectorAll("[data-stats-pin]").forEach((el) => {
      const at = this.pins.indexOf(Number(el.dataset.statsPin))
      el.classList.toggle("is-pinned", at >= 0)
      el.classList.toggle("is-pin-dull", at >= 0 && pinStyle(at, p).dull)
      el.style.setProperty("--pin-color", at >= 0 ? pinStyle(at, p).color : "transparent")
    })
  }

  fail() {
    this.chart?.dispose()
    this.chart = null
    this.element.textContent = "chart unavailable"
    this.element.classList.add("muted")
  }
}

function palette() {
  const style = getComputedStyle(document.documentElement)
  const v = (name) => style.getPropertyValue(name).trim()
  return {
    slots: [v("--stats-c1"), v("--stats-c2"), v("--stats-c3"), v("--stats-c4"), v("--stats-c5")],
    gray: v("--stats-gray"), gray2: v("--stats-gray2"),
    card: v("--color-bg-card"), border: v("--color-border"),
    text: v("--color-text-primary"), muted: v("--color-text-muted"),
    phase: v("--stats-phase"), cf: v("--stats-cf"),
  }
}

const esc = (s) => echarts.format.encodeHTML(String(s ?? ""))

// gray items skip the categorical slots
function slotColors(items, p) {
  let n = 0
  return items.map((s) => s.gray ? p.gray : p.slots[n++ % p.slots.length])
}

const base = (p) => ({
  animation: false,
  textStyle: { color: p.muted, fontFamily: "inherit" },
  tooltip: { backgroundColor: p.card, borderColor: p.border, textStyle: { color: p.text, fontSize: 12 } },
})

// bars in a tile, axes hidden, bucket names on hover
// data: { categories: [], values: [], unit: "" }
function bars(data, p) {
  const o = base(p)
  o.tooltip.trigger = "axis"
  o.tooltip.formatter = (ps) => `${esc(ps[0].name)}: ${ps[0].value} ${esc(data.unit)}`
  o.grid = { left: 4, right: 4, top: 4, bottom: 4 }
  o.xAxis = { type: "category", show: false, data: data.categories }
  o.yAxis = { type: "value", show: false }
  o.series = [{ type: "bar", data: data.values, barWidth: "72%",
                itemStyle: { color: p.slots[0], borderRadius: [3, 3, 0, 0] } }]
  return o
}

// one stacked horizontal bar with percentages, legend entries explain
// themselves on hover
// data: { segments: [{ label, value, definition, gray }] }
function share(data, p) {
  const o = base(p)
  const segs = data.segments
  const total = segs.reduce((s, r) => s + r.value, 0) || 1
  const colors = slotColors(segs, p)
  o.tooltip.trigger = "item"
  o.tooltip.formatter = (x) => `<b>${esc(x.seriesName)}</b>: ${x.value} (${Math.round(x.value / total * 100)}%)` +
    (segs[x.seriesIndex].definition ? `<br><span style="color:${p.muted}">${esc(segs[x.seriesIndex].definition)}</span>` : "")
  o.legend = { bottom: 0, left: 0, itemWidth: 10, itemHeight: 10, textStyle: { color: p.muted, fontSize: 11 },
               tooltip: { show: true, formatter: (x) => esc(segs.find((s) => s.label === x.name)?.definition || x.name) } }
  o.grid = { left: 0, right: 0, top: 4, bottom: 22 }
  o.xAxis = { type: "value", show: false, max: total }
  o.yAxis = { type: "category", show: false, data: [""] }
  o.series = segs.map((s, i) => ({
    name: s.label, type: "bar", stack: "s", data: [s.value], barWidth: 18,
    itemStyle: { color: colors[i], borderColor: p.card, borderWidth: 1 },
    label: { show: s.value / total > 0.1, position: "inside", color: "#fff", fontSize: 11,
             formatter: () => Math.round(s.value / total * 100) + "%" },
  }))
  return o
}

// grouped bars with bucket labels on the axis and a legend
// data: { categories: [], series: [{ label, values, gray }], labels }; labels: false hides the axis
function histogram(data, p) {
  const o = base(p)
  o.tooltip.trigger = "axis"
  o.legend = { bottom: 0, left: 0, itemGap: 14, itemWidth: 10, itemHeight: 10, textStyle: { color: p.muted, fontSize: 11 } }
  o.grid = { left: 0, right: 0, top: 4, bottom: 36 }
  o.xAxis = { type: "category", data: data.categories, axisTick: { show: false }, axisLine: { show: false },
              axisLabel: { fontSize: 10, color: p.muted, interval: 0 } }
  if (data.labels === false) {
    o.xAxis.axisLabel = { show: false }
    o.grid.bottom = 22
  }
  o.yAxis = { type: "value", show: false }
  const colors = slotColors(data.series, p)
  o.series = data.series.map((s, i) => ({
    name: s.label, type: "bar", data: s.values, barGap: "10%",
    itemStyle: { color: colors[i], borderRadius: [3, 3, 0, 0] },
  }))
  return o
}

// the Pulse tab: a header grid holding the phase and commitfest bands with
// their labels, then one grid per strip, all on one linked time axis.
// data: { gran, buckets: [{start, label, phase}], windows: [{from, to, phase}],
//         bands: [{from, to, label}], events: [{at, label}],
//         strips: [{ key, label, unit, split, committers, others | values }] }
function strips(data, p, el) {
  const o = base(p)
  const n = data.strips.length
  const headH = 30, top = 10, gap = 34
  const total = el.clientHeight || 60 + n * 125
  const width = (el.clientWidth || 1000) - 64
  const h = (total - top - headH - 40 - gap * n) / n
  const gridTop = (i) => top + headH + gap + i * (h + gap)
  const ts = (s) => new Date(s).getTime()
  const starts = data.buckets.map((b) => ts(b.start))
  const last = starts.length - 1
  const step = (j) => j < last ? starts[j + 1] - starts[j] : (last > 0 ? starts[last] - starts[last - 1] : 7 * 864e5)
  const ends = starts.map((s, j) => s + step(j))
  const xs = starts.map((s, j) => (s + ends[j]) / 2)
  const x0 = starts[0], x1 = ends[last]
  const area = (from, to, color, name) => {
    const a = Math.max(ts(from), x0), b = Math.min(ts(to), x1)
    return a < b ? [[{ xAxis: a, itemStyle: { color }, name }, { xAxis: b }]] : []
  }
  const phaseAreas = data.windows.filter((w) => w.phase !== "middle")
    .flatMap((w) => area(w.from, w.to, p.phase, w.phase === "early" ? "early" : "stabilization"))
  const bandAreas = data.bands.flatMap((b) => area(b.from, b.to, p.cf, b.label))
  // narrow bands go unlabelled, their name is in the tooltip
  const labelled = (position) => ([a, b]) => [{ ...a, label: {
    show: (b.xAxis - a.xAxis) / (x1 - x0) * width >= 40, position, formatter: a.name, color: p.muted, fontSize: 11 } }, b]
  const headerAreas = [...phaseAreas.map(labelled("insideTopLeft")), ...bandAreas.map(labelled("insideBottom"))]
  const quietAreas = [...phaseAreas, ...bandAreas].map(([a, b]) => [{ xAxis: a.xAxis, itemStyle: a.itemStyle }, b])
  const eventLines = { silent: true, symbol: "none", lineStyle: { type: "dashed", color: p.muted, width: 1 }, label: { show: false },
                       data: data.events.map((e) => ts(e.at)).filter((t) => t >= x0 && t <= x1).map((t) => ({ xAxis: t })) }
  const axisX = (i, last) => ({ type: "time", gridIndex: i, min: x0, max: x1, axisLabel: { show: last, color: p.muted, fontSize: 11 },
                                axisLine: { lineStyle: { color: p.border } }, axisTick: { show: false }, splitLine: { show: false } })
  // bucket index holding a time, null outside the cycle
  const bucketAt = (value) => {
    const t = ts(value)
    if (!(t >= x0 && t < x1)) return null
    let best = 0
    starts.forEach((s, j) => { if (s <= t) best = j })
    return best
  }
  o.tooltip.trigger = "axis"
  o.tooltip.formatter = (ps) => {
    const i = bucketAt(ps[0].axisValue)
    if (i === null) return ""
    const b = data.buckets[i]
    const tag = b.phase === "middle" ? "everything on the lists" : (b.phase === "early" ? "early" : "stabilization") + ": threads that landed only"
    const band = data.bands.find((x) => ts(x.from) < ends[i] && ts(x.to) >= starts[i])
    const ev = data.events.find((e) => bucketAt(e.at) === i)
    const head = `<b>${esc(b.label)}</b><br><span style="color:${p.muted}">${esc(tag)}${band ? " · " + esc(band.label) : ""}${ev ? " · " + esc(ev.label) : ""}</span>`
    const rows = data.strips.map((s) => s.split
      ? `<b>${esc(s.label)}</b>: ${s.committers[i] + s.others[i]} <span style="color:${p.muted}">(${s.committers[i]} committers, ${s.others[i]} others)</span>`
      : `<b>${esc(s.label)}</b>: ${s.values[i]}`)
    return head + "<br>" + rows.join("<br>")
  }
  o.axisPointer = { link: [{ xAxisIndex: "all" }], lineStyle: { color: p.slots[0] }, label: { show: false } }
  o.title = data.strips.map((s, i) => ({ text: s.label, left: 48, top: gridTop(i) - 20, textStyle: { color: p.text, fontSize: 12, fontWeight: 600 } }))
  o.grid = [{ left: 48, right: 16, top, height: headH }].concat(data.strips.map((_, i) => ({ left: 48, right: 16, top: gridTop(i), height: h })))
  o.xAxis = [{ ...axisX(0, false), show: false }].concat(data.strips.map((_, i) => axisX(i + 1, i === n - 1)))
  o.yAxis = [{ type: "value", gridIndex: 0, show: false, min: 0, max: 1 }].concat(data.strips.map((_, i) => ({
    type: "value", gridIndex: i + 1, axisLabel: { color: p.muted, fontSize: 10 }, splitLine: { lineStyle: { color: p.border, type: "dotted" } }, splitNumber: 2 })))
  // marks on the first series of a strip only, stacked twice they darken
  const bar = (i, name, values, color, marks = true) => ({
    name, type: "bar", stack: "s" + i, xAxisIndex: i + 1, yAxisIndex: i + 1, barWidth: "62%",
    data: xs.map((x, j) => [x, values[j]]), itemStyle: { color, borderColor: p.card, borderWidth: 1 },
    ...(marks && { markArea: { silent: true, data: quietAreas }, markLine: eventLines }),
  })
  // a hidden bar so the header axis gets the same edge padding as the strips
  o.series = [{ type: "bar", xAxisIndex: 0, yAxisIndex: 0, barWidth: "62%", data: xs.map((x) => [x, 0]), itemStyle: { opacity: 0 },
                silent: true, tooltip: { show: false }, markArea: { silent: true, data: headerAreas }, markLine: eventLines }]
    .concat(data.strips.flatMap((s, i) => s.split
      ? [bar(i, s.label + " (committers)", s.committers, p.slots[0]), bar(i, s.label, s.others, p.slots[1], false)]
      : [bar(i, s.label, s.values, p.slots[0])]))
  return o
}

// one dot per point, a series per group; points with x + y >= label_min get their name
// data: { x_label, y_label, groups: [{ key, label }], points: [{ x, y, name, group, size }], label_min }
function scatter(data, p) {
  const o = base(p)
  const axis = (name) => ({ type: "value", name, nameLocation: "middle", nameGap: 24, nameTextStyle: { color: p.muted, fontSize: 11 },
                            axisLabel: { color: p.muted, fontSize: 10 }, splitLine: { lineStyle: { color: p.border, type: "dotted" } }, axisLine: { show: false } })
  const min = data.label_min ?? Infinity
  o.tooltip.trigger = "item"
  o.tooltip.formatter = (x) => `<b>${esc(x.data[2])}</b>: ${x.data[0]} ${esc(data.x_label)}, ${x.data[1]} ${esc(data.y_label)}`
  const multi = data.groups.length > 1
  if (multi) o.legend = { top: 0, right: 0, itemWidth: 10, itemHeight: 10, textStyle: { color: p.muted, fontSize: 11 } }
  o.grid = { left: 44, right: 60, top: multi ? 28 : 12, bottom: 36 }
  o.xAxis = axis(data.x_label)
  o.yAxis = axis(data.y_label)
  o.labelLayout = { hideOverlap: true }
  o.series = data.groups.map((g, i) => ({
    name: g.label, type: "scatter", symbolSize: 8, z: 3,
    itemStyle: { color: p.slots[i % p.slots.length], borderColor: p.card, borderWidth: 2 },
    data: data.points.filter((pt) => pt.group === g.key).map((pt) => [pt.x, pt.y, pt.name]),
    label: { show: true, position: "right", fontSize: 10, color: p.muted,
             formatter: (x) => x.data[0] + x.data[1] >= min ? x.data[2] : "" },
  }))
  // the half below y = x shaded, a caption in each corner
  if (data.diagonal) {
    const top = Math.max(1, ...data.points.flatMap((pt) => [pt.x, pt.y]))
    o.xAxis.max = top
    o.yAxis.max = top
    o.series.push({ type: "line", data: [[0, 0], [top, top]], symbol: "none", silent: true, z: 1,
                    lineStyle: { color: p.border, width: 1, type: "dashed" }, areaStyle: { color: p.phase } })
    o.graphic = [
      { type: "text", right: 64, bottom: 42, style: { text: data.diagonal.below, fill: p.muted, fontSize: 10, align: "right" } },
      { type: "text", left: 50, top: multi ? 34 : 18, style: { text: data.diagonal.above, fill: p.muted, fontSize: 10 } },
    ]
  }
  return o
}

// horizontal stacked bars, one per category, top first; the last gray_tail
// categories are drawn gray, the bar end shows the total or its percent_of share
// data: { categories: [], series: [{ label, values, gray }], total_labels, number_labels, percent_of, gray_tail, max }
function ranked(data, p) {
  const o = base(p)
  const colors = slotColors(data.series, p)
  const n = data.categories.length
  const tailFrom = n - (data.gray_tail || 0)
  const multi = data.series.length > 1
  const totals = data.categories.map((_, j) => data.series.reduce((s, x) => s + (x.values[j] || 0), 0))
  const fmt = (v) => data.number_labels ? Number(v).toLocaleString("en-US") : v
  const endLabel = (j) => data.percent_of ? Math.round(totals[j] / data.percent_of * 100) + "%"
    : fmt(totals[j])
  o.tooltip.trigger = "axis"
  o.tooltip.axisPointer = { type: "shadow" }
  o.tooltip.formatter = (ps) => `<b>${esc(ps[0].name)}</b>` +
    (multi ? "<br>" + ps.map((x) => `${x.marker} ${esc(x.seriesName)}: ${fmt(x.value)}`).join("<br>") : `: ${fmt(ps[0].value)}`)
  if (multi) o.legend = { top: 0, right: 16, itemWidth: 10, itemHeight: 10, textStyle: { color: p.muted, fontSize: 11 } }
  o.grid = { left: 150, right: 44, top: multi ? 28 : 6, bottom: 4 }
  o.xAxis = { type: "value", show: false, max: data.max }
  o.yAxis = { type: "category", inverse: true, data: data.categories, axisTick: { show: false }, axisLine: { show: false },
              axisLabel: { color: p.text, fontSize: 11, interval: 0, width: 140, overflow: "truncate" } }
  const last = data.series.length - 1
  o.series = data.series.map((s, i) => {
    const tail = i % 2 ? p.gray2 : p.gray
    return {
      name: s.label, type: "bar", stack: "a", barWidth: "66%",
      data: s.values.map((v, j) => j >= tailFrom ? { value: v, itemStyle: { color: tail } } : v),
      itemStyle: { color: colors[i], borderColor: p.card, borderWidth: 1, borderRadius: i === last ? [0, 3, 3, 0] : 0 },
      label: i === last && data.total_labels
        ? { show: true, position: "right", fontSize: 10, color: p.muted, formatter: (x) => endLabel(x.dataIndex) } : undefined,
    }
  })
  return o
}

// one bar row per company or committer, all on one scale, name and total
// beside it; a folded row (fold: true) may hold far more, so it is gray and
// as many rows tall as its peak needs, up to ROWS_FOLD_MAX. Early and
// stabilization months are shaded
// data: { buckets: ["Oct 2025", ...], windows: [{ from, to, phase }], series: [{ label, values, fold }] }
const ROW_H = 26, ROWS_AXIS_H = 34, ROWS_FOLD_MAX = 4
function rows(data, p, el) {
  const o = base(p)
  const n = data.series.length
  const left = 150, right = 56
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  const keyOf = (t) => { const d = new Date(t); return d.getUTCFullYear() * 12 + d.getUTCMonth() }
  const keys = data.buckets.map((b) => { const [m, y] = String(b).split(" "); return Number(y) * 12 + months.indexOf(m) })
  const areas = (data.windows || []).filter((w) => w.phase !== "middle").flatMap((w) => {
    const from = keyOf(w.from), to = keyOf(new Date(w.to).getTime() - 1)
    const a = keys.findIndex((k) => k >= from), b = keys.findLastIndex((k) => k <= to)
    return a >= 0 && a <= b ? [[{ xAxis: data.buckets[a], itemStyle: { color: p.phase } }, { xAxis: data.buckets[b] }]] : []
  })
  const named = data.series.filter((s) => !s.fold)
  const max = Math.max(1, ...(named.length ? named : data.series).flatMap((s) => s.values))
  const peak = (s) => Math.max(0, ...s.values)
  const span = (s) => s.fold ? Math.min(ROWS_FOLD_MAX, Math.max(1, Math.ceil(peak(s) / max))) : 1
  const tops = []
  let y = 0
  data.series.forEach((s) => { tops.push(y); y += span(s) * ROW_H })
  el.style.height = `${y + ROWS_AXIS_H}px`
  const total = (s) => s.values.reduce((a, b) => a + b, 0).toLocaleString("en-US")
  o.tooltip.trigger = "item"
  o.tooltip.formatter = (x) => `<b>${esc(data.series[x.seriesIndex].label)}</b><br>${esc(data.buckets[x.dataIndex])}: ${x.value}`
  o.grid = data.series.map((s, i) => ({ left, right, top: tops[i] + 3, height: span(s) * ROW_H - 6 }))
  o.xAxis = data.series.map((_, i) => ({
    gridIndex: i, type: "category", data: data.buckets, axisTick: { show: false }, axisLine: { show: false },
    axisLabel: { show: i === n - 1, interval: 0, fontSize: 9, lineHeight: 11, color: p.muted, margin: 10,
                 formatter: (label, j) => { const [m, y] = String(label).split(" "); return m === "Jan" || j === 0 ? `${m}\n${y}` : m } },
  }))
  // a folded row past the cap is squeezed and says so
  o.yAxis = data.series.map((s, i) => ({ gridIndex: i, type: "value", show: false, max: Math.max(max * span(s), peak(s)) }))
  o.series = data.series.map((s, i) => ({
    type: "bar", xAxisIndex: i, yAxisIndex: i, data: s.values, barWidth: "72%",
    itemStyle: { color: s.fold ? p.gray : p.slots[0] }, markArea: { silent: true, data: areas },
  }))
  o.graphic = data.series.flatMap((s, i) => [
    { type: "text", left: 0, top: tops[i] + 7, style: { text: s.label, fill: s.fold ? p.muted : p.text, fontSize: 11, width: left - 10, overflow: "truncate" } },
    { type: "text", right: 0, top: tops[i] + 7, style: { text: total(s), fill: p.muted, fontSize: 11, align: "right" } },
    ...(peak(s) > max * span(s) ? [{ type: "text", left: 0, top: tops[i] + 21, style: { text: `squeezed, peak ${peak(s)}`, fill: p.muted, fontSize: 9 } }] : []),
    ...(i ? [{ type: "line", left: 0, right: 0, top: tops[i], shape: { x1: 0, y1: 0, x2: el.clientWidth || 600, y2: 0 }, style: { stroke: p.border, lineWidth: 1 } }] : []),
  ])
  return o
}

// one point per period, null is a gap; open periods are hollow points at
// the end of a dashed segment, closed ones are filled
// data: { categories: [], lines: [{ label, values }], unit, open: [bool], partial, paths }
function trend(data, p) {
  const o = base(p)
  const open = (j) => !!data.open?.[j]
  const colors = slotColors(data.lines, p)
  const gray = (i) => !!data.lines[i].gray
  const fmt = (v) => v == null ? "n/a" : data.unit === "%" ? `${v}%` : `${Number(v).toLocaleString()}${data.unit ? " " + data.unit : ""}`
  o.tooltip.trigger = "axis"
  o.tooltip.formatter = (ps) => {
    const shown = ps.filter((x) => !x.seriesId.endsWith(":open") && !gray(x.seriesIndex / 2))
    const j = ps[0].dataIndex
    const note = open(j) ? ` <span style="color:${p.muted}">in progress${data.partial ? ", partial" : ""}</span>` : ""
    return `<b>${esc(ps[0].name)}</b>${note}` +
      shown.map((x) => `<br>${data.lines.length > 1 ? esc(x.seriesName) + ": " : ""}${esc(fmt(data.lines[x.seriesIndex / 2].values[j]))}`).join("")
  }
  if (data.lines.length > 1) {
    o.legend = { data: data.lines.filter((l) => !l.gray).map((l) => l.label), bottom: 0, left: 0, itemWidth: 10, itemHeight: 10,
                 textStyle: { color: p.muted, fontSize: 11 } }
  }
  const legendChars = data.lines.filter((l) => !l.gray).reduce((n, l) => n + l.label.length + 4, 0)
  o.grid = { left: 4, right: 16, top: 8, bottom: data.lines.length < 2 ? 4 : legendChars > 45 ? 44 : 24, containLabel: true }
  o.xAxis = { type: "category", data: data.categories, boundaryGap: false, axisTick: { show: false },
              axisLine: { lineStyle: { color: p.border } }, axisLabel: { fontSize: 10, color: p.muted, hideOverlap: true } }
  o.yAxis = { type: "value", min: 0, splitLine: { lineStyle: { color: p.border } }, axisLabel: { fontSize: 10, color: p.muted } }
  const cursor = data.paths ? "pointer" : "default"
  o.series = data.lines.flatMap((l, i) => {
    const closed = l.values.map((v, j) => open(j) ? null : v)
    // the open tail: from the last closed point on, nulls elsewhere
    const firstOpen = l.values.findIndex((_, j) => open(j))
    const tail = l.values.map((v, j) => firstOpen >= 0 && j >= firstOpen - 1 ? v : null)
    return [
      { id: `${i}:closed`, name: l.label, type: "line", connectNulls: false, symbol: "circle", symbolSize: 6, cursor,
        lineStyle: { color: colors[i], width: gray(i) ? 1 : 2 }, itemStyle: { color: colors[i] }, data: closed, z: gray(i) ? 1 : 3,
        ...(gray(i) ? { symbol: "none" } : {}) },
      { id: `${i}:open`, name: l.label, type: "line", connectNulls: false, symbol: "emptyCircle", symbolSize: 7, cursor,
        lineStyle: { color: colors[i], width: gray(i) ? 1 : 2, type: "dashed", opacity: 0.6 },
        itemStyle: { color: colors[i], opacity: 0.6 },
        data: tail.map((v, j) => open(j) ? v : { value: v, symbol: "none" }), z: gray(i) ? 1 : 2,
        ...(gray(i) ? { symbol: "none" } : {}) },
    ]
  })
  return o
}

// stacked areas over time; gray series skip the slots
// data: { categories: [], series: [{ label, values, gray }], unit, open: [bool], bars }
function stack(data, p) {
  const o = base(p)
  const colors = slotColors(data.series, p)
  const fmt = (v) => v == null ? "n/a" : data.unit === "%" ? `${v}%` : Number(v).toLocaleString()
  o.tooltip.trigger = "axis"
  o.tooltip.formatter = (ps) => {
    const j = ps[0].dataIndex
    const note = data.open?.[j] ? ` <span style="color:${p.muted}">in progress</span>` : ""
    return `<b>${esc(ps[0].name)}</b>${note}` + ps.slice().reverse().map((x) => `<br>${esc(x.seriesName)}: ${esc(fmt(x.value))}`).join("")
  }
  o.legend = { data: data.series.map((s) => s.label), bottom: 0, left: 0, itemWidth: 10, itemHeight: 10,
               textStyle: { color: p.muted, fontSize: 11 } }
  o.grid = { left: 4, right: 16, top: 8, bottom: 24, containLabel: true }
  o.xAxis = { type: "category", data: data.categories, boundaryGap: !!data.bars, axisTick: { show: false },
              axisLine: { lineStyle: { color: p.border } }, axisLabel: { fontSize: 10, color: p.muted, hideOverlap: true } }
  o.yAxis = { type: "value", min: 0, ...(data.unit === "%" ? { max: (v) => Math.max(100, Math.ceil(v.max)) } : {}),
              splitLine: { lineStyle: { color: p.border } }, axisLabel: { fontSize: 10, color: p.muted } }
  o.series = data.series.map((s, i) => data.bars ? ({
    name: s.label, type: "bar", stack: "all", barWidth: "60%", itemStyle: { color: colors[i] }, data: s.values,
  }) : ({
    name: s.label, type: "line", stack: "all", symbol: "none", lineStyle: { width: 0 },
    areaStyle: { color: colors[i], opacity: 0.85 }, itemStyle: { color: colors[i] }, data: s.values,
  }))
  return o
}

function fade(color, alpha) {
  const el = document.createElement("span")
  el.style.color = color
  document.body.appendChild(el)
  const rgb = getComputedStyle(el).color.match(/[\d.]+/g)
  el.remove()
  return rgb ? `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, ${alpha})` : color
}

// people x months, color by rank band; click a column to pick the month
// data: { x: [], y: [], cells: [[x, y, band, rank, score]], paths: [] }
function heatmap(data, p) {
  const o = base(p)
  const shades = [fade(p.slots[0], 0.22), fade(p.slots[0], 0.45), fade(p.slots[0], 0.7), p.slots[0]]
  o.tooltip.formatter = (e) => `${esc(data.y[e.value[1]])}, ${esc(data.x[e.value[0]])}: rank ${e.value[3]}, score ${e.value[4]}`
  o.grid = { left: 4, right: 8, top: 4, bottom: 4, containLabel: true }
  o.xAxis = { type: "category", data: data.x, splitArea: { show: false }, axisTick: { show: false },
              axisLine: { lineStyle: { color: p.border } }, axisLabel: { fontSize: 10, color: p.muted, hideOverlap: true } }
  o.yAxis = { type: "category", data: data.y, inverse: true, axisTick: { show: false }, axisLine: { show: false },
              axisLabel: { fontSize: 11, color: p.text, interval: 0 } }
  o.visualMap = { show: false, type: "piecewise", dimension: 2,
                  pieces: [1, 2, 3, 4].map((b) => ({ value: b, color: shades[b - 1] })) }
  o.series = [{ type: "heatmap", data: data.cells, cursor: data.paths ? "pointer" : "default",
                itemStyle: { borderColor: p.card, borderWidth: 1 } }]
  return o
}

// rank over time, 1 on top; gaps when outside the top 20
// data: { categories: [], lines: [{ label, values }] }
// gray field of everyone, pinned people in color; p.pins is the pin order
// p.pins[slot] = person id; slots 0-4 solid, 5-9 the same hues dashed
const PIN_SLOTS = 10
const pinStyle = (slot, p) => ({ color: p.slots[slot % p.slots.length], dull: slot >= p.slots.length })

// gray field of everyone, pinned people in color, the end month's top 20 named on the right
function bump(data, p) {
  const o = base(p)
  const pins = p.pins || []
  o.tooltip.trigger = "item"
  o.tooltip.formatter = (x) => `<b>${esc(x.seriesName)}</b><br>${esc(x.name)}: ${x.value}.`
  o.grid = { left: 4, right: 150, top: 8, bottom: 4, containLabel: true }
  o.xAxis = { type: "category", data: data.categories, boundaryGap: false, axisTick: { show: false },
              axisLine: { lineStyle: { color: p.border } }, axisLabel: { fontSize: 10, color: p.muted, hideOverlap: true } }
  o.yAxis = { type: "value", inverse: true, min: 1, max: 20, interval: 1, splitLine: { show: false },
              axisLabel: { fontSize: 10, color: p.muted } }
  const lastCat = data.categories.length - 1
  const slotOf = (l) => pins.indexOf(l.id)
  const lines = [...data.lines].sort((a, b) => (slotOf(a) >= 0) - (slotOf(b) >= 0))
  o.series = lines.map((l) => {
    const slot = slotOf(l)
    const st = slot < 0 ? null : pinStyle(slot, p)
    const color = st ? st.color : p.gray2
    const last = l.values.reduce((acc, v, j) => v == null ? acc : j, -1)
    const named = st || last === lastCat
    const label = { show: true, position: "right", formatter: () => l.label, fontSize: 10,
                    color: st ? p.text : p.muted, fontWeight: st && !st.dull ? "bold" : "normal" }
    return { name: l.label, id: String(l.id), type: "line", connectNulls: false, symbol: "circle",
             symbolSize: st ? 5 : 4, z: st ? 3 : 1,
             lineStyle: { color, width: st ? (st.dull ? 2 : 2.5) : 1, type: st?.dull ? [ 5, 3 ] : "solid", opacity: st?.dull ? 0.8 : 1 },
             itemStyle: { color },
             triggerLineEvent: true, cursor: "pointer",
             emphasis: { focus: "series", lineStyle: { width: 3, color: st ? color : p.text }, itemStyle: { color: st ? color : p.text },
                         label: { color: p.text, fontWeight: "bold" } },
             blur: { lineStyle: { opacity: 0.2 }, itemStyle: { opacity: 0.2 }, label: { opacity: 0.4 } },
             data: l.values.map((v, j) => named && j === last ? { value: v, label } : v) }
  })
  return o
}

const BUILDERS = { spark: bars, bars, share, histogram, strips, scatter, ranked, rows, trend, stack, heatmap, bump }
