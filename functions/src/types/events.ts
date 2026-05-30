// api-spec-v2 §6.4 events.d.ts 전사 (FCM 6개 이벤트)
import type { UserId } from "./common";

export interface FcmEventBase {
  type: string;
  timestamp: number;
  actorId?: UserId;
  gameSessionId?: string;
  participationId?: string;
  actionUrl: string;
  title: string;
  body: string;
}

export interface ParticipationDecisionEvent extends FcmEventBase {
  type: "participation.decision";
  data: { decision: "approved" | "rejected"; reason?: string };
}

export interface PaymentRequestedEvent extends FcmEventBase {
  type: "payment.requested";
  data: {
    bankName: string;
    accountNumber: string;
    accountHolder: string;
    gameFee: string;
    cancelDeadline: string;
  };
}

export interface PaymentDecisionEvent extends FcmEventBase {
  type: "payment.decision";
  data: { decision: "approved" | "rejected"; reason?: string };
}

export interface ParticipationConfirmedEvent extends FcmEventBase {
  type: "participation.confirmed";
  data: { entryPassId: string };
}

export interface SessionUpcomingReminderEvent extends FcmEventBase {
  type: "session.upcoming_reminder";
  data: { startsAt: string; fieldName: string };
}

export interface SessionChangedEvent extends FcmEventBase {
  type: "session.changed";
  data: { type: "updated" | "cancelled"; changedFields?: string; reason?: string };
}

export type FcmEvent =
  | ParticipationDecisionEvent
  | PaymentRequestedEvent
  | PaymentDecisionEvent
  | ParticipationConfirmedEvent
  | SessionUpcomingReminderEvent
  | SessionChangedEvent;
