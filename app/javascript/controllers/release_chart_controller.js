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
      this.chart.setOption(builder(this.dataValue, palette(), this.element))
    } catch (e) {
      this.fail()
    }
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

const BUILDERS = { spark: bars, bars, share, histogram, strips, scatter, ranked, rows }
