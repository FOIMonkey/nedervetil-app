// Calendar-day gap helpers; kept pure so spec/javascripts/thread_gaps_test.js runs in Node.

// Parse only the YYYY-MM-DD prefix in UTC so browser timezone and DST can't shift the day.
export function calendarDay(iso) {
  const match = /^(\d{4})-(\d{2})-(\d{2})(?:T|$)/.exec(iso || "")
  if (!match || isNaN(new Date(iso))) { return null }

  const [year, month, date] = [Number(match[1]), Number(match[2]) - 1, Number(match[3])]
  const day = new Date(0)
  day.setUTCFullYear(year, month, date)
  day.setUTCHours(0, 0, 0, 0)
  if (day.getUTCFullYear() !== year || day.getUTCMonth() !== month || day.getUTCDate() !== date) {
    return null
  }
  return day.getTime()
}

export function daysBetween(earlier, later) {
  const a = calendarDay(earlier)
  const b = calendarDay(later)
  if (a === null || b === null) { return null }
  return Math.round((b - a) / 86400000)
}

export function gapText(days) {
  if (days <= 0) { return "Same day" }
  if (days === 1) { return "1 day later" }
  return `${days} days later`
}
