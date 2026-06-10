import { describe, expect, it } from "vitest";
import { shouldDeleteFcmToken } from "../notifications/notifier";

describe("notifier", () => {
  describe("shouldDeleteFcmToken", () => {
    it("등록 해제된 토큰은 삭제 대상으로 판정한다", () => {
      expect(
        shouldDeleteFcmToken("messaging/registration-token-not-registered")
      ).toBe(true);
    });

    it("무관한 에러 코드는 유지 대상으로 판정한다", () => {
      expect(shouldDeleteFcmToken("messaging/internal-error")).toBe(false);
    });
  });
});
