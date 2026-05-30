import { describe, expect, it } from "vitest";
import { HttpsError } from "firebase-functions/v2/https";
import {
  assertCapacityAvailable,
  assertSessionStatusAllows,
  reachesCapacityAfterIncrement
} from "../lib/guards";

describe("guards", () => {
  describe("B1-1 정원 가드 (confirmedCount 기준)", () => {
    it("여유 있으면 통과", () => {
      expect(() =>
        assertCapacityAvailable({ confirmedCount: 9, capacity: 10 })
      ).not.toThrow();
    });

    it("가득 차면 failed-precondition", () => {
      try {
        assertCapacityAvailable({ confirmedCount: 10, capacity: 10 });
        throw new Error("should throw");
      } catch (e) {
        expect(e).toBeInstanceOf(HttpsError);
        expect((e as HttpsError).code).toBe("failed-precondition");
      }
    });

    it("reachesCapacityAfterIncrement: +1 시 정원 도달 여부", () => {
      expect(reachesCapacityAfterIncrement({ confirmedCount: 9, capacity: 10 })).toBe(true);
      expect(reachesCapacityAfterIncrement({ confirmedCount: 8, capacity: 10 })).toBe(false);
    });
  });

  describe("B1-2 세션상태 화이트리스트", () => {
    it("requestParticipation은 recruiting만 허용", () => {
      expect(() =>
        assertSessionStatusAllows("requestParticipation", { status: "recruiting" })
      ).not.toThrow();
      expect(() =>
        assertSessionStatusAllows("requestParticipation", { status: "closed" })
      ).toThrow(HttpsError);
    });

    it("approvePayment은 recruiting/closed 허용, inProgress/completed/cancelled 차단", () => {
      expect(() =>
        assertSessionStatusAllows("approvePayment", { status: "recruiting" })
      ).not.toThrow();
      expect(() =>
        assertSessionStatusAllows("approvePayment", { status: "closed" })
      ).not.toThrow();
      expect(() =>
        assertSessionStatusAllows("approvePayment", { status: "inProgress" })
      ).toThrow(HttpsError);
      expect(() =>
        assertSessionStatusAllows("approvePayment", { status: "completed" })
      ).toThrow(HttpsError);
      expect(() =>
        assertSessionStatusAllows("approvePayment", { status: "cancelled" })
      ).toThrow(HttpsError);
    });
  });
});
