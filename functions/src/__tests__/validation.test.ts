import { describe, expect, it } from "vitest";
import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import {
  asNonEmptyString,
  assertProfileComplete,
  isProfileComplete,
  optionalString,
  validateCreateGameSessionInput,
  validateSessionUpdates
} from "../lib/validation";

function expectHttpsCode(fn: () => void, code: HttpsError["code"]): void {
  try {
    fn();
    throw new Error("should throw");
  } catch (e) {
    expect(e).toBeInstanceOf(HttpsError);
    expect((e as HttpsError).code).toBe(code);
  }
}

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

  describe("validateSessionUpdates", () => {
    const startsAtMs = Date.UTC(2026, 0, 10, 9, 0, 0);
    const baseSession = {
      capacity: 10,
      confirmedCount: 0,
      presetId: null,
      startsAtMs
    };

    it("허용 필드는 검증 후 필드 목록을 반환한다", () => {
      const cancelDeadline = Timestamp.fromMillis(startsAtMs - 2 * 24 * 60 * 60 * 1000);
      const updates = {
        title: "변경된 게임",
        customRules: { rounds: 4 },
        cancelDeadline,
        capacity: 12,
        gameFee: 35_000,
        endsAt: Timestamp.fromMillis(startsAtMs + 2 * 60 * 60 * 1000)
      };

      expect(() =>
        validateSessionUpdates(
          updates,
          baseSession,
          cancelDeadline.toMillis()
        )
      ).not.toThrow();
      expect(
        validateSessionUpdates(updates, baseSession, cancelDeadline.toMillis())
      ).toEqual([
        "title",
        "customRules",
        "cancelDeadline",
        "capacity",
        "gameFee",
        "endsAt"
      ]);
    });

    it("startsAt/status/미지 키는 invalid-argument", () => {
      expectHttpsCode(
        () => validateSessionUpdates({ startsAt: Timestamp.now() }, baseSession),
        "invalid-argument"
      );
      expectHttpsCode(
        () => validateSessionUpdates({ status: "cancelled" }, baseSession),
        "invalid-argument"
      );
      expectHttpsCode(
        () => validateSessionUpdates({ unknown: true }, baseSession),
        "invalid-argument"
      );
    });

    it("capacity 감소와 확정 인원 미만 변경을 거부한다", () => {
      expectHttpsCode(
        () => validateSessionUpdates({ capacity: 9 }, baseSession),
        "failed-precondition"
      );
      expectHttpsCode(
        () =>
          validateSessionUpdates(
            { capacity: 11 },
            { ...baseSession, confirmedCount: 12 }
          ),
        "failed-precondition"
      );
    });

    it("확정자가 있으면 gameFee 변경을 거부한다", () => {
      expectHttpsCode(
        () =>
          validateSessionUpdates(
            { gameFee: 40_000 },
            { ...baseSession, confirmedCount: 1 }
          ),
        "failed-precondition"
      );
    });

    it("프리셋 세션의 customRules 변경을 거부한다", () => {
      expectHttpsCode(
        () =>
          validateSessionUpdates(
            { customRules: { rounds: 4 } },
            { ...baseSession, presetId: "preset-1" }
          ),
        "failed-precondition"
      );
    });

    it("cancelDeadline은 startsAt-7d~startsAt-24h 범위 밖이면 거부한다", () => {
      const tooEarly = startsAtMs - 8 * 24 * 60 * 60 * 1000;
      const tooLate = startsAtMs - 12 * 60 * 60 * 1000;

      expectHttpsCode(
        () =>
          validateSessionUpdates(
            { cancelDeadline: Timestamp.fromMillis(tooEarly) },
            baseSession,
            tooEarly
          ),
        "invalid-argument"
      );
      expectHttpsCode(
        () =>
          validateSessionUpdates(
            { cancelDeadline: Timestamp.fromMillis(tooLate) },
            baseSession,
            tooLate
          ),
        "invalid-argument"
      );
    });
  });
});
