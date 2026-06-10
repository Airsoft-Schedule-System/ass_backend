import { SESSION_STATUS, PARTICIPATION_STATUS } from "./status";
import type { GameSessionStatus, ParticipationStatus } from "../types/status";

const DAY_MS = 24 * 60 * 60 * 1000;
const REMINDER_WINDOW_MS = 30 * 60 * 1000;

export const CANCELLABLE_PARTICIPATION_STATUS: ReadonlySet<ParticipationStatus> =
  new Set([
    PARTICIPATION_STATUS.PENDING_APPROVAL,
    PARTICIPATION_STATUS.AWAITING_PAYMENT,
    PARTICIPATION_STATUS.PAYMENT_REVIEW,
    PARTICIPATION_STATUS.CONFIRMED
  ]);

export function isRefundEligible(
  previousStatus: ParticipationStatus,
  cancelDeadlineMs: number,
  nowMs: number
): boolean {
  return previousStatus === PARTICIPATION_STATUS.CONFIRMED && nowMs < cancelDeadlineMs;
}

export function isInReminderWindow(startsAtMs: number, nowMs: number): boolean {
  const reminderTargetMs = nowMs + DAY_MS;
  return (
    startsAtMs >= reminderTargetMs - REMINDER_WINDOW_MS &&
    startsAtMs <= reminderTargetMs + REMINDER_WINDOW_MS
  );
}

export function nextSessionStatus(
  session: {
    status: GameSessionStatus;
    confirmedCount: number;
    capacity: number;
    startsAtMs: number;
    endsAtMs: number | null;
  },
  nowMs: number
): GameSessionStatus | null {
  if (
    session.status === SESSION_STATUS.RECRUITING &&
    session.confirmedCount >= session.capacity
  ) {
    return SESSION_STATUS.CLOSED;
  }

  if (
    (session.status === SESSION_STATUS.RECRUITING ||
      session.status === SESSION_STATUS.CLOSED) &&
    session.startsAtMs <= nowMs
  ) {
    return SESSION_STATUS.IN_PROGRESS;
  }

  const endsAtMs = session.endsAtMs ?? session.startsAtMs + DAY_MS;
  if (session.status === SESSION_STATUS.IN_PROGRESS && endsAtMs <= nowMs) {
    return SESSION_STATUS.COMPLETED;
  }

  return null;
}
