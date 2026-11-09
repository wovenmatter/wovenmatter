/**
 * 5-field cron (`minute hour day-of-month month day-of-week`) as `[extraction] schedule` uses it:
 * `*`, numbers, ranges `a-b`, steps `/n` and comma lists. Day of week 0-7 (0 and 7 are Sunday).
 * When both day fields are restricted, either may match (classic cron).
 */
export type CronSchedule = {
  /** Whether the schedule fires in the minute of `at`, read in `timeZone`. */
  matches(at: Date | number, timeZone: string): boolean;
};

const FIELDS = [
  { name: "minute", min: 0, max: 59 },
  { name: "hour", min: 0, max: 23 },
  { name: "day of month", min: 1, max: 31 },
  { name: "month", min: 1, max: 12 },
  { name: "day of week", min: 0, max: 7 },
] as const;

function parseField(text: string, min: number, max: number, name: string): Set<number> {
  const values = new Set<number>();
  for (const part of text.split(",")) {
    const match = /^(\*|(\d+)(?:-(\d+))?)(?:\/(\d+))?$/.exec(part);
    if (!match) throw new Error(`invalid cron ${name}: ${part}`);
    const step = match[4] === undefined ? 1 : Number(match[4]);
    let from = min;
    let to = max;
    if (match[1] !== "*") {
      from = Number(match[2]);
      // `a/n` runs from a to the end of the range.
      to = match[3] !== undefined ? Number(match[3]) : match[4] !== undefined ? max : from;
    }
    if (from < min || to > max || from > to || step < 1) {
      throw new Error(`invalid cron ${name}: ${part} (allowed ${min}-${max})`);
    }
    for (let value = from; value <= to; value += step) values.add(value);
  }
  return values;
}

const WEEKDAYS: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
const formatters = new Map<string, Intl.DateTimeFormat>();

/** Minute, hour, day, month and weekday of `at` in `timeZone`. */
export function zonedParts(at: Date | number, timeZone: string): number[] {
  let format = formatters.get(timeZone);
  if (!format) {
    format = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      minute: "numeric",
      hour: "numeric",
      day: "numeric",
      month: "numeric",
      weekday: "short",
    });
    formatters.set(timeZone, format);
  }
  const parts = Object.fromEntries(
    format.formatToParts(at).map((part) => [part.type, part.value]),
  ) as Record<string, string>;
  return [
    Number(parts.minute),
    Number(parts.hour),
    Number(parts.day),
    Number(parts.month),
    WEEKDAYS[parts.weekday ?? ""] ?? 0,
  ];
}

/** Parse a 5-field cron expression; throws with the offending field. */
export function parseCron(expression: string): CronSchedule {
  const texts = expression.trim().split(/\s+/);
  if (texts.length !== 5) throw new Error("expected 5 cron fields");
  const sets = FIELDS.map((field, index) =>
    parseField(texts[index] ?? "", field.min, field.max, field.name),
  );
  const [minutes, hours, days, months, weekdays] = sets as [
    Set<number>,
    Set<number>,
    Set<number>,
    Set<number>,
    Set<number>,
  ];
  if (weekdays.has(7)) weekdays.add(0);
  const anyDay = texts[2] === "*";
  const anyWeekday = texts[4] === "*";
  return {
    matches(at, timeZone) {
      const [minute, hour, day, month, weekday] = zonedParts(at, timeZone) as [
        number,
        number,
        number,
        number,
        number,
      ];
      if (!minutes.has(minute) || !hours.has(hour) || !months.has(month)) return false;
      const dayOk = days.has(day);
      const weekdayOk = weekdays.has(weekday);
      if (anyDay || anyWeekday) return dayOk && weekdayOk;
      return dayOk || weekdayOk;
    },
  };
}

export function isCronExpression(value: string): boolean {
  try {
    parseCron(value);
    return true;
  } catch {
    return false;
  }
}
