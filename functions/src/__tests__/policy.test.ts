import { describe, expect, it } from "vitest";
import {
  CANCELLABLE_PARTICIPATION_STATUS,
  isRefundEligible,
  nextSessionStatus
} from "../lib/policy";
import { PARTICIPATION_STATUS, SESSION_STATUS } from "../lib/status";

describe("policy", () => {
  describe("isRefundEligible", () => {
    it("confirmed 상태이고 마감 전이면 true", () => {
      expect(isRefundEligible(PARTICIPATION_STATUS.CONFIRMED, 1_000, 999)).toBe(true);
    });

    it("confirmed라도 마감 후면 false", () => {
      expect(isRefundEligible(PARTICIPATION_STATUS.CONFIRMED, 1_000, 1_000)).toBe(false);
    });

    it("confirmed가 아니면 false", () => {
      expect(
        isRefundEligible(PARTICIPATION_STATUS.AWAITING_PAYMENT, 1_000, 999)
      ).toBe(false);
    });
  });

  describe("nextSessionStatus", () => {
    const base = {
      confirmedCount: 5,
      capacity: 10,
      startsAtMs: 2_000,
      endsAtMs: 3_000
    };

    it("recruiting 정원 도달 → closed", () => {
      expect(
        nextSessionStatus(
          {
            ...base,
            status: SESSION_STATUS.RECRUITING,
            confirmedCount: 10
          },
          1_000
        )
      ).toBe(SESSION_STATUS.CLOSED);
    });

    it("startsAt 경과 → inProgress (recruiting/closed)", () => {
      expect(
        nextSessionStatus({ ...base, status: SESSION_STATUS.RECRUITING }, 2_000)
      ).toBe(SESSION_STATUS.IN_PROGRESS);
      expect(
        nextSessionStatus({ ...base, status: SESSION_STATUS.CLOSED }, 2_000)
      ).toBe(SESSION_STATUS.IN_PROGRESS);
    });

    it("endsAt 경과 → completed", () => {
      expect(
        nextSessionStatus({ ...base, status: SESSION_STATUS.IN_PROGRESS }, 3_000)
      ).toBe(SESSION_STATUS.COMPLETED);
    });

    it("endsAt이 없으면 startsAt+24h 기준으로 completed", () => {
      const dayMs = 24 * 60 * 60 * 1000;
      expect(
        nextSessionStatus(
          {
            ...base,
            status: SESSION_STATUS.IN_PROGRESS,
            endsAtMs: null
          },
          base.startsAtMs + dayMs
        )
      ).toBe(SESSION_STATUS.COMPLETED);
    });

    it("전이 조건이 없으면 null", () => {
      expect(
        nextSessionStatus({ ...base, status: SESSION_STATUS.RECRUITING }, 1_000)
      ).toBeNull();
    });
  });

  describe("CANCELLABLE_PARTICIPATION_STATUS", () => {
    it("취소 가능한 4개 상태를 허용한다", () => {
      expect(CANCELLABLE_PARTICIPATION_STATUS.has("pendingApproval")).toBe(true);
      expect(CANCELLABLE_PARTICIPATION_STATUS.has("awaitingPayment")).toBe(true);
      expect(CANCELLABLE_PARTICIPATION_STATUS.has("paymentReview")).toBe(true);
      expect(CANCELLABLE_PARTICIPATION_STATUS.has("confirmed")).toBe(true);
    });

    it("취소 불가 상태는 차단한다", () => {
      expect(CANCELLABLE_PARTICIPATION_STATUS.has("rejected")).toBe(false);
      expect(CANCELLABLE_PARTICIPATION_STATUS.has("attended")).toBe(false);
      expect(CANCELLABLE_PARTICIPATION_STATUS.has("cancelled")).toBe(false);
      expect(CANCELLABLE_PARTICIPATION_STATUS.has("refundRequested")).toBe(false);
    });
  });
});
