import { describe, expect, it } from "vitest";
import { buildEntryPassToken, hashEntryPassToken, QR_SECRET_VERSION } from "../lib/qr";

const baseFields = {
  entryPassId: "entry-pass-1",
  gameSessionId: "session-1",
  userId: "user-1",
  issuedAtMs: 1_717_000_000_000,
  version: QR_SECRET_VERSION
};

describe("qr", () => {
  it("같은 입력과 같은 시크릿이면 같은 토큰을 만든다", () => {
    const a = buildEntryPassToken(baseFields, "secret-a");
    const b = buildEntryPassToken(baseFields, "secret-a");

    expect(a).toBe(b);
  });

  it("시크릿이나 필드가 바뀌면 다른 토큰을 만든다", () => {
    const token = buildEntryPassToken(baseFields, "secret-a");

    expect(buildEntryPassToken(baseFields, "secret-b")).not.toBe(token);
    expect(
      buildEntryPassToken({ ...baseFields, entryPassId: "entry-pass-2" }, "secret-a")
    ).not.toBe(token);
    expect(
      buildEntryPassToken({ ...baseFields, gameSessionId: "session-2" }, "secret-a")
    ).not.toBe(token);
    expect(
      buildEntryPassToken({ ...baseFields, userId: "user-2" }, "secret-a")
    ).not.toBe(token);
    expect(
      buildEntryPassToken({ ...baseFields, issuedAtMs: baseFields.issuedAtMs + 1 }, "secret-a")
    ).not.toBe(token);
    expect(
      buildEntryPassToken({ ...baseFields, version: "v2" }, "secret-a")
    ).not.toBe(token);
  });

  it("토큰 해시는 SHA256 hex로 검증할 수 있다", () => {
    const token = buildEntryPassToken(baseFields, "secret-a");
    const hash = hashEntryPassToken(token);

    expect(hash).toMatch(/^[a-f0-9]{64}$/);
    expect(hashEntryPassToken(token)).toBe(hash);
  });

  it("토큰은 base64url 문자만 사용한다", () => {
    const token = buildEntryPassToken(baseFields, "secret-a");

    expect(token).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(token).not.toContain("=");
    expect(token).not.toContain("+");
    expect(token).not.toContain("/");
  });
});
