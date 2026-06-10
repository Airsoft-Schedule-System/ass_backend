import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes
} from "node:crypto";

const VERSION = "v1";
const ALGORITHM = "aes-256-gcm";
const IV_BYTES = 12;

function deriveKey(secretValue: string): Buffer {
  return createHash("sha256").update(secretValue).digest();
}

export function encryptRefundAccount(plain: string, secretValue: string): string {
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv(ALGORITHM, deriveKey(secretValue), iv);
  const ciphertext = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();

  return [
    VERSION,
    iv.toString("base64"),
    ciphertext.toString("base64"),
    tag.toString("base64")
  ].join(":");
}

export function decryptRefundAccount(encoded: string, secretValue: string): string {
  const [version, ivBase64, ciphertextBase64, tagBase64, ...extra] =
    encoded.split(":");
  if (
    version !== VERSION ||
    !ivBase64 ||
    !ciphertextBase64 ||
    !tagBase64 ||
    extra.length > 0
  ) {
    throw new Error("Invalid refund account ciphertext");
  }

  const decipher = createDecipheriv(
    ALGORITHM,
    deriveKey(secretValue),
    Buffer.from(ivBase64, "base64")
  );
  decipher.setAuthTag(Buffer.from(tagBase64, "base64"));

  return Buffer.concat([
    decipher.update(Buffer.from(ciphertextBase64, "base64")),
    decipher.final()
  ]).toString("utf8");
}
