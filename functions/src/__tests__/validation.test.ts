import { describe, expect, it } from "vitest";
import { HttpsError } from "firebase-functions/v2/https";
import {
  asNonEmptyString,
  assertProfileComplete,
  isProfileComplete,
  optionalString,
  validateCreateGameSessionInput
} from "../lib/validation";

describe("validation", () => {
  describe("B1-6 프로필 필수값(displayName)", () => {
    it("displayName 비어있지 않으면 완성", () => {
      expect(isProfileComplete({ displayName: "철수" })).toBe(true);
      expect(isProfileComplete({ displayName: "  " })).toBe(false);
      expect(isProfileComplete({ displayName: null })).toBe(false);
      expect(isProfileComplete({})).toBe(false);
    });

    it("미완성이면 failed-precondition", () => {
      try {
        assertProfileComplete({ displayName: "" });
        throw new Error("should throw");
      } catch (e) {
        expect(e).toBeInstanceOf(HttpsError);
        expect((e as HttpsError).code).toBe("failed-precondition");
      }
    });
  });

  describe("createGameSession 입력 검증 (api-spec §2.2)", () => {
    const base = {
      title: "일요 교전",
      capacity: 20,
      gameFee: 30000,
      fieldName: "파주 필드",
      customRules: { rounds: 3 }
    };

    it("정상 입력은 통과", () => {
      expect(() => validateCreateGameSessionInput(base)).not.toThrow();
    });

    it("fieldId XOR fieldName 위반 → invalid-argument", () => {
      // 둘 다
      expect(() =>
        validateCreateGameSessionInput({ ...base, fieldId: "f1" })
      ).toThrow(HttpsError);
      // 둘 다 없음
      const { fieldName: _f, ...noField } = base;
      expect(() => validateCreateGameSessionInput(noField)).toThrow(HttpsError);
    });

    it("presetId XOR customRules 위반 → invalid-argument", () => {
      // 둘 다
      expect(() =>
        validateCreateGameSessionInput({ ...base, presetId: "p1" })
      ).toThrow(HttpsError);
      // 둘 다 없음
      const { customRules: _r, ...noRules } = base;
      expect(() => validateCreateGameSessionInput(noRules)).toThrow(HttpsError);
    });

    it("capacity<=0, gameFee<0 → invalid-argument", () => {
      expect(() =>
        validateCreateGameSessionInput({ ...base, capacity: 0 })
      ).toThrow(HttpsError);
      expect(() =>
        validateCreateGameSessionInput({ ...base, gameFee: -1 })
      ).toThrow(HttpsError);
    });
  });

  describe("문자열 헬퍼", () => {
    it("asNonEmptyString", () => {
      expect(asNonEmptyString("x", "f")).toBe("x");
      expect(() => asNonEmptyString("", "f")).toThrow(HttpsError);
      expect(() => asNonEmptyString(123, "f")).toThrow(HttpsError);
    });

    it("optionalString", () => {
      expect(optionalString("x")).toBe("x");
      expect(optionalString("")).toBeNull();
      expect(optionalString(undefined)).toBeNull();
    });
  });
});
