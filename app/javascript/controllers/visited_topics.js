const STORAGE_KEY = "hackorum:visited-topics"
const LIMIT = 50

export function all() {
  try {
    const raw = window.sessionStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed.filter(id => Number.isInteger(id)) : []
  } catch (e) {
    console.warn("visited topics read failed", e)
    return []
  }
}

export function remember(id) {
  if (!Number.isInteger(id) || id <= 0) return

  try {
    const kept = all().filter(existing => existing !== id)
    kept.push(id)
    window.sessionStorage.setItem(STORAGE_KEY, JSON.stringify(kept.slice(-LIMIT)))
  } catch (e) {
    console.warn("visited topics write failed", e)
  }
}
