// api-spec-v2 §6.2 status.d.ts 전사 (ERD §9 상태 모델)
export type GameSessionStatus =
  | "recruiting"
  | "closed"
  | "inProgress"
  | "completed"
  | "cancelled";

export type ParticipationStatus =
  | "pendingApproval"
  | "rejected"
  | "awaitingPayment"
  | "paymentReview"
  | "confirmed"
  | "cancelled"
  | "refundRequested"
  | "attended";

export type PaymentSubmissionStatus = "pending" | "approved" | "rejected";

export type RefundRequestStatus =
  | "requested"
  | "approved"
  | "completed"
  | "rejected";

export type EntryPassStatus = "active" | "used" | "revoked" | "expired";

export type FcmTokenPlatform = "web" | "ios" | "android";
