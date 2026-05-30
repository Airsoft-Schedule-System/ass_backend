import { describe, expect, it } from "vitest";
import {
  ENTRY_PASS_STATUS,
  PARTICIPATION_STATUS,
  PAYMENT_METHOD,
  PAYMENT_SUBMISSION_STATUS,
  REFUND_STATUS,
  SESSION_STATUS,
  TERMINAL_PARTICIPATION_STATUS,
  TERMINAL_SESSION_STATUS
} from "../lib/status";

describe("status 상수 (ERD §9 정합)", () => {
  it("GameSession 상태 5개", () => {
    expect(Object.values(SESSION_STATUS).sort()).toEqual([
      "cancelled",
      "closed",
      "completed",
      "inProgress",
      "recruiting"
    ]);
  });

  it("Participation 상태 8개 (noShow 제외)", () => {
    expect(Object.values(PARTICIPATION_STATUS)).toHaveLength(8);
    expect(Object.values(PARTICIPATION_STATUS)).toContain("paymentReview");
    expect(Object.values(PARTICIPATION_STATUS)).toContain("confirmed");
    expect(Object.values(PARTICIPATION_STATUS)).not.toContain("noShow");
  });

  it("PaymentSubmission 상태 3개", () => {
    expect(Object.values(PAYMENT_SUBMISSION_STATUS)).toEqual([
      "pending",
      "approved",
      "rejected"
    ]);
  });

  it("Refund/EntryPass 상태 4개", () => {
    expect(Object.values(REFUND_STATUS)).toHaveLength(4);
    expect(Object.values(ENTRY_PASS_STATUS)).toHaveLength(4);
  });

  it("결제수단은 pre_transfer 단일 (현장결제 미지원)", () => {
    expect(PAYMENT_METHOD.PRE_TRANSFER).toBe("pre_transfer");
    expect(Object.values(PAYMENT_METHOD)).toHaveLength(1);
  });

  it("terminal 집합", () => {
    expect(TERMINAL_SESSION_STATUS.has("completed")).toBe(true);
    expect(TERMINAL_SESSION_STATUS.has("recruiting")).toBe(false);
    expect(TERMINAL_PARTICIPATION_STATUS.has("attended")).toBe(true);
    expect(TERMINAL_PARTICIPATION_STATUS.has("confirmed")).toBe(false);
  });
});
