import { Timestamp } from "firebase-admin/firestore";
import { errInvalidArgument } from "./errors";

export function toTimestamp(value: unknown, field: string): Timestamp {
  if (value instanceof Timestamp) return value;
  if (typeof value === "number") return Timestamp.fromMillis(value);
  if (typeof value === "string") {
    const ms = Date.parse(value);
    if (!Number.isNaN(ms)) return Timestamp.fromMillis(ms);
  }
  if (value && typeof value === "object") {
    const o = value as {
      _seconds?: number;
      seconds?: number;
      _nanoseconds?: number;
      nanoseconds?: number;
    };
    const seconds = o._seconds ?? o.seconds;
    if (typeof seconds === "number") {
      return new Timestamp(seconds, o._nanoseconds ?? o.nanoseconds ?? 0);
    }
  }
  throw errInvalidArgument(`${field}는 유효한 시각이어야 합니다`);
}
