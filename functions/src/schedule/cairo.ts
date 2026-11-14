import { DAYS, type Day } from "../carpools/model";

/**
 * Cairo calendar helpers (Prompt 7). Every schedule date is a Cairo date
 * ("YYYY-MM-DD") and every run time a Cairo wall-clock time ("HH:MM").
 * Egypt observes daylight saving time again since 2023 (UTC+3 from the
 * last Friday of April to the last Thursday of October, UTC+2 otherwise),
 * so conversions to instants always go through the Africa/Cairo zone of
 * the ICU time zone data, never a fixed offset.
 */

export const CAIRO_TZ = "Africa/Cairo";

const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME = /^([01]\d|2[0-3]):([0-5]\d)$/;

const offsetFormat = new Intl.DateTimeFormat("en-US", {
  timeZone: CAIRO_TZ,
  hourCycle: "h23",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

/** Minutes Cairo is ahead of UTC at the instant [utcMs] (120 in winter, 180 in summer). */
export function cairoOffsetMinutes(utcMs: number): number {
  const parts = Object.fromEntries(offsetFormat.formatToParts(new Date(utcMs)).map((p) => [p.type, p.value]));
  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return Math.round((asUtc - Math.floor(utcMs / 1000) * 1000) / 60_000);
}

export function isDate(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const m = DATE.exec(value);
  if (!m) return false;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCFullYear() === Number(m[1]) && d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]);
}

function dateParts(date: string): [number, number, number] {
  const m = DATE.exec(date);
  if (!m) throw new Error("bad date");
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

/**
 * The instant of Cairo wall-clock [time] on [date]. Times in the spring
 * gap (none of our run times: runs are 05:00 to 22:00 and Cairo changes
 * clocks at midnight) resolve to the later offset.
 */
export function cairoToUtcMs(date: string, time: string): number {
  const [y, mo, d] = dateParts(date);
  const t = TIME.exec(time);
  if (!t) throw new Error("bad time");
  const naive = Date.UTC(y, mo - 1, d, Number(t[1]), Number(t[2]));
  let guess = naive - cairoOffsetMinutes(naive - 120 * 60_000) * 60_000;
  // Second pass settles the offset when the first guess fell across a change.
  guess = naive - cairoOffsetMinutes(guess) * 60_000;
  return guess;
}

/** [date] plus [days] calendar days. */
export function addDays(date: string, days: number): string {
  const [y, m, d] = dateParts(date);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

/** Whole calendar days from [a] to [b] (negative when b is earlier). */
export function daysBetween(a: string, b: string): number {
  const [y1, m1, d1] = dateParts(a);
  const [y2, m2, d2] = dateParts(b);
  return Math.round((Date.UTC(y2, m2 - 1, d2) - Date.UTC(y1, m1 - 1, d1)) / 86_400_000);
}

/** The weekday code of a Cairo date. */
export function weekdayOf(date: string): Day {
  const [y, m, d] = dateParts(date);
  const js = new Date(Date.UTC(y, m - 1, d)).getUTCDay(); // 0 = Sunday
  return DAYS[(js + 1) % 7];
}

/** The Saturday that starts the Egyptian week of [date] (Saturday to Friday). */
export function weekStartOf(date: string): string {
  return addDays(date, -DAYS.indexOf(weekdayOf(date)));
}

/** The seven dates of the week that starts on [weekStart]. */
export function weekDates(weekStart: string): string[] {
  return Array.from({ length: 7 }, (_, i) => addDays(weekStart, i));
}

/**
 * School term of a date, for the drive balance (F37). Egyptian schools run
 * a first term from September to January and a second from February to
 * the summer: "2026-t1" is September 2026 to January 2027.
 */
export function termOf(date: string): { id: string; from: string; to: string } {
  const [y, m] = dateParts(date);
  if (m >= 9) return { id: `${y}-t1`, from: `${y}-09-01`, to: `${y + 1}-01-31` };
  if (m === 1) return { id: `${y - 1}-t1`, from: `${y - 1}-09-01`, to: `${y}-01-31` };
  return { id: `${y - 1}-t2`, from: `${y}-02-01`, to: `${y}-08-31` };
}
