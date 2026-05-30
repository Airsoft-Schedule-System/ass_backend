import { describe, expect, it } from "vitest";
import { HttpsError } from "firebase-functions/v2/https";
import {
  assertParticipantOrOwner,
  assertSessionOwner,
  isParticipant,
  isSessionOwner,
  requireAuth
} from "../lib/permissions";

describe("permissions (세션 단위 권한, 고정 역할 없음)", () => {
  const session = { createdByUserId: "owner-1" };

  it("isSessionOwner: createdByUserId === uid", () => {
    expect(isSessionOwner(session, "owner-1")).toBe(true);
    expect(isSessionOwner(session, "other")).toBe(false);
  });

  it("isParticipant: participation.userId === uid", () => {
    expect(isParticipant({ userId: "u1" }, "u1")).toBe(true);
    expect(isParticipant({ userId: "u1" }, "u2")).toBe(false);
  });

  it("requireAuth: 미인증이면 unauthenticated, 인증되면 uid 반환", () => {
    expect(requireAuth({ uid: "u1" })).toBe("u1");
    try {
      requireAuth(undefined);
      throw new Error("should throw");
    } catch (e) {
      expect(e).toBeInstanceOf(HttpsError);
      expect((e as HttpsError).code).toBe("unauthenticated");
    }
  });

  it("assertSessionOwner: 운영자 아니면 permission-denied", () => {
    expect(() => assertSessionOwner(session, "owner-1")).not.toThrow();
    try {
      assertSessionOwner(session, "other");
      throw new Error("should throw");
    } catch (e) {
      expect((e as HttpsError).code).toBe("permission-denied");
    }
  });

  it("assertParticipantOrOwner: 본인 또는 운영자만 허용", () => {
    const part = { userId: "u1" };
    expect(() => assertParticipantOrOwner(part, session, "u1")).not.toThrow();
    expect(() => assertParticipantOrOwner(part, session, "owner-1")).not.toThrow();
    try {
      assertParticipantOrOwner(part, session, "stranger");
      throw new Error("should throw");
    } catch (e) {
      expect((e as HttpsError).code).toBe("permission-denied");
    }
  });
});
