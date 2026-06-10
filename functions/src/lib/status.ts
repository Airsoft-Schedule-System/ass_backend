// B3-3 seam: 상태 리터럴을 함수마다 하드코딩하지 않도록 BE 내부 단일 출처로 둔다.
// (교차 레포 FE/BE 공유 패키지화 = B3-2, 선행 A6 → 보류. 여기서는 BE 내부 상수만.)
import type {
  EntryPassStatus,
  GameSessionStatus,
  ParticipationStatus,
  PaymentSubmissionStatus,
  RefundRequestStatus
} from "../types/status";

export const SESSION_STATUS = {
  RECRUITING: "recruiting",
  CLOSED: "closed",
  IN_PROGRESS: "inProgress",
  COMPLETED: "completed",
  CANCELLED: "cancelled"
} as const satisfies Record<string, GameSessionStatus>;

export const PARTICIPATION_STATUS = {
  PENDING_APPROVAL: "pendingApproval",
  REJECTED: "rejected",
  AWAITING_PAYMENT: "awaitingPayment",
  PAYMENT_REVIEW: "paymentReview",
  CONFIRMED: "confirmed",
  CANCELLED: "cancelled",
  REFUND_REQUESTED: "refundRequested",
  ATTENDED: "attended"
} as const satisfies Record<string, ParticipationStatus>;

export const PAYMENT_SUBMISSION_STATUS = {
  PENDING: "pending",
  APPROVED: "approved",
  REJECTED: "rejected"
} as const satisfies Record<string, PaymentSubmissionStatus>;

export const REFUND_STATUS = {
  REQUESTED: "requested",
  APPROVED: "approved",
  COMPLETED: "completed",
  REJECTED: "rejected"
} as const satisfies Record<string, RefundRequestStatus>;

export const ENTRY_PASS_STATUS = {
  ACTIVE: "active",
  USED: "used",
  REVOKED: "revoked",
  EXPIRED: "expired"
} as const satisfies Record<string, EntryPassStatus>;

// §10.1 결제 방식 — seam (현장결제 대비 enum 확장 여지)
export const PAYMENT_METHOD = {
  PRE_TRANSFER: "pre_transfer"
} as const;

export const TERMINAL_SESSION_STATUS: ReadonlySet<GameSessionStatus> = new Set([
  SESSION_STATUS.COMPLETED,
  SESSION_STATUS.CANCELLED
]);

export const TERMINAL_PARTICIPATION_STATUS: ReadonlySet<ParticipationStatus> = new Set([
  PARTICIPATION_STATUS.REJECTED,
  PARTICIPATION_STATUS.ATTENDED
]);
