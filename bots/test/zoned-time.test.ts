import { describe, expect, it } from "vitest";
import { isTimeZone, parseDate, parseTimeOfDay, zonedEpoch, zonedTime } from "../src/zoned-time.ts";

describe("zoned time", () => {
  it("reads a moment as a zone's clock shows it", () => {
    expect(zonedTime(Date.parse("2026-11-18T15:30:00Z"), "America/Chicago")).toEqual({
      year: 2026,
      month: 11,
      day: 18,
      hour: 9,
      minute: 30,
      weekday: 3,
    });
    // Past midnight UTC it is still the day before in Chicago.
    expect(zonedTime(Date.parse("2026-01-01T03:00:00Z"), "America/Chicago")).toMatchObject({
      year: 2025,
      month: 12,
      day: 31,
      hour: 21,
      weekday: 3,
    });
  });

  it("finds when a zone's clock shows a time, on both sides of a daylight-saving change", () => {
    expect(zonedEpoch(2026, 11, 18, 9, 0, "America/Chicago")).toBe(Date.parse("2026-11-18T15:00:00Z"));
    expect(zonedEpoch(2026, 7, 1, 9, 0, "America/Chicago")).toBe(Date.parse("2026-07-01T14:00:00Z"));
    expect(zonedEpoch(2026, 7, 1, 9, 0, "UTC")).toBe(Date.parse("2026-07-01T09:00:00Z"));
    expect(zonedEpoch(2026, 7, 1, 9, 0, "Asia/Kolkata")).toBe(Date.parse("2026-07-01T03:30:00Z"));
  });

  it("parses times of day, dates and zone names", () => {
    expect(parseTimeOfDay("09:05")).toEqual({ hour: 9, minute: 5 });
    expect(parseTimeOfDay("23:59")).toEqual({ hour: 23, minute: 59 });
    for (const bad of ["24:00", "9:05", "09:60", "", "noon"]) expect(parseTimeOfDay(bad)).toBeUndefined();
    expect(parseDate("2026-02-28")).toEqual({ year: 2026, month: 2, day: 28 });
    for (const bad of ["2026-02-30", "2026-13-01", "26-02-01", ""]) expect(parseDate(bad)).toBeUndefined();
    expect(isTimeZone("Europe/Berlin")).toBe(true);
    expect(isTimeZone("Mars/Olympus")).toBe(false);
  });
});
