import { describe, expect, it } from "vitest";
import { decryptRefundAccount, encryptRefundAccount } from "../lib/crypto";

describe("refund account crypto", () => {
  it("암호화 후 같은 키로 복호화할 수 있다", () => {
    const encrypted = encryptRefundAccount("110-123-456789", "secret-a");

    expect(encrypted.startsWith("v1:")).toBe(true);
    expect(decryptRefundAccount(encrypted, "secret-a")).toBe("110-123-456789");
  });

  it("다른 키로는 복호화할 수 없다", () => {
    const encrypted = encryptRefundAccount("110-123-456789", "secret-a");

    expect(() => decryptRefundAccount(encrypted, "secret-b")).toThrow();
  });

  it("ciphertext 위변조를 거부한다", () => {
    const encrypted = encryptRefundAccount("110-123-456789", "secret-a");
    const [version, iv, ciphertext, tag] = encrypted.split(":");
    const replacement = ciphertext.endsWith("A") ? "B" : "A";
    const tampered = [version, iv, `${ciphertext.slice(0, -1)}${replacement}`, tag].join(":");

    expect(() => decryptRefundAccount(tampered, "secret-a")).toThrow();
  });
});
