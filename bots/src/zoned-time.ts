/** A wall-clock moment in one IANA time zone. `weekday` is 0 (Sunday) to 6. */
export type ZonedTime = {
  readonly year: number;
  readonly month: number;
  readonly day: number;
  readonly hour: number;
  readonly minute: number;
  readonly weekday: number;
};

const formatters = new Map<string, Intl.DateTimeFormat>();

export function isTimeZone(value: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value });
    return true;
  } catch {
    return false;
  }
}

/** The machine's own time zone (the bots machine is the user's). */
export function localTimeZone(): string {
  return new Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

/** `at` (epoch ms) as the clock in `timeZone` shows it. */
export function zonedTime(at: number, timeZone: string): ZonedTime {
  let format = formatters.get(timeZone);
  if (!format) {
    format = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
    });
    formatters.set(timeZone, format);
  }
  const parts = Object.fromEntries(
    format.formatToParts(at).map((part) => [part.type, Number(part.value)]),
  ) as Record<string, number>;
  const year = parts.year ?? 1970;
  const month = parts.month ?? 1;
  const day = parts.day ?? 1;
  return {
    year,
    month,
    day,
    hour: parts.hour ?? 0,
    minute: parts.minute ?? 0,
    weekday: new Date(Date.UTC(year, month - 1, day)).getUTCDay(),
  };
}

/**
 * The epoch ms at which the clock in `timeZone` shows the given date and time. A time a
 * daylight-saving change skips resolves to the moment the clock jumps past it.
 */
export function zonedEpoch(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  timeZone: string,
): number {
  const wanted = Date.UTC(year, month - 1, day, hour, minute);
  let guess = wanted;
  for (let pass = 0; pass < 3; pass += 1) {
    const shown = zonedTime(guess, timeZone);
    const difference =
      wanted - Date.UTC(shown.year, shown.month - 1, shown.day, shown.hour, shown.minute);
    if (difference === 0) break;
    guess += difference;
  }
  return guess;
}

/** `HH:MM` as hour and minute, or undefined when it is not a time of day. */
export function parseTimeOfDay(
  value: string,
): { readonly hour: number; readonly minute: number } | undefined {
  const match = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(value);
  return match ? { hour: Number(match[1]), minute: Number(match[2]) } : undefined;
}

/** `YYYY-MM-DD` as a calendar date, or undefined when it is not one. */
export function parseDate(
  value: string,
): { readonly year: number; readonly month: number; readonly day: number } | undefined {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return undefined;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const check = new Date(Date.UTC(year, month - 1, day));
  return check.getUTCFullYear() === year &&
    check.getUTCMonth() === month - 1 &&
    check.getUTCDate() === day
    ? { year, month, day }
    : undefined;
}
