// api-spec-v2 §6.3 functions.d.ts 전사 (콜러블 Input/Output)
import type { BankAccount, Timestamp } from "./common";
import type { RefundRequestStatus } from "./status";

// 2.2 createGameSession
export interface CreateGameSessionInput {
  title: string;
  startsAt: Timestamp;
  endsAt?: Timestamp;
  fieldId?: string;
  fieldName?: string;
  hostTeamId?: string;
  capacity: number;
  gameFee: number;
  bankAccount: BankAccount;
  presetId?: string;
  customRules?: Record<string, unknown>;
  cancelDeadline?: Timestamp;
}
export interface CreateGameSessionOutput {
  success: true;
  gameSessionId: string;
}

// 2.3 updateGameSession
export interface UpdateGameSessionInput {
  gameSessionId: string;
  updates: Partial<{
    title: string;
    customRules: Record<string, unknown>;
    cancelDeadline: Timestamp;
    capacity: number;
    gameFee: number;
    endsAt: Timestamp;
  }>;
}
export interface UpdateGameSessionOutput {
  success: true;
  updatedFields: string[];
}

// 2.4 cancelGameSession
export interface CancelGameSessionInput {
  gameSessionId: string;
  reason?: string;
}
export interface CancelGameSessionOutput {
  success: true;
  affectedParticipations: number;
}

// 2.6 requestParticipation
export interface RequestParticipationInput {
  gameSessionId: string;
}
export interface RequestParticipationOutput {
  success: true;
  participationId: string;
  status: "pendingApproval";
}

// 2.6a joinAsOperator (A7 — 운영자 자기 게임 참가, 자동확정)
export interface JoinAsOperatorInput {
  gameSessionId: string;
}
export interface JoinAsOperatorOutput {
  success: true;
  participationId: string;
  status: "confirmed";
}

// 2.7 approveParticipation
export interface ApproveParticipationInput {
  participationId: string;
}
export interface ApproveParticipationOutput {
  success: true;
  newStatus: "awaitingPayment";
}

// 2.8 rejectParticipation
export interface RejectParticipationInput {
  participationId: string;
  reason?: string;
}
export interface RejectParticipationOutput {
  success: true;
}

// 2.9 cancelParticipation
export interface CancelParticipationInput {
  participationId: string;
  reason?: string;
}
export interface CancelParticipationOutput {
  success: true;
  refundEligible: boolean;
}

// 2.10 submitPayment
export interface SubmitPaymentInput {
  participationId: string;
  senderName: string;
  amount: number;
  receiptImageUrl: string;
}
export interface SubmitPaymentOutput {
  success: true;
  paymentSubmissionId: string;
}

// 2.11 approvePayment
export interface ApprovePaymentInput {
  paymentSubmissionId: string;
}
export interface ApprovePaymentOutput {
  success: true;
  participationId: string;
}

// 2.12 rejectPayment
export interface RejectPaymentInput {
  paymentSubmissionId: string;
  reason: string;
}
export interface RejectPaymentOutput {
  success: true;
}

// 2.13 requestRefund
export interface RequestRefundInput {
  participationId: string;
  bankName: string;
  accountNumber: string;
  accountHolder: string;
  reason?: string;
}
export interface RequestRefundOutput {
  success: true;
  refundRequestId: string;
}

// 2.14 processRefund
export interface ProcessRefundInput {
  refundRequestId: string;
  decision: "approved" | "completed" | "rejected";
  note?: string;
}
export interface ProcessRefundOutput {
  success: true;
  newStatus: RefundRequestStatus;
}

// 2.16 getEntryPassToken
export interface GetEntryPassTokenInput {
  gameSessionId: string;
}
export interface GetEntryPassTokenOutput {
  entryPassId: string;
  token: string;
  expiresAt: Timestamp;
}

// 2.17 scanEntryPass
export interface ScanEntryPassInput {
  qrPayload: {
    entryPassId: string;
    token: string;
  };
}
export interface ScanEntryPassOutput {
  success: true;
  userId: string;
  displayName: string;
}
