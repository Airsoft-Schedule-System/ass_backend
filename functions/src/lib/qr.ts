import { createHash, createHmac } from "node:crypto";

export const QR_SECRET_VERSION = "v1";

export interface EntryPassTokenFields {
  entryPassId: string;
  gameSessionId: string;
  userId: string;
  issuedAtMs: number;
  version: string;
}

function serializeEntryPassTokenFields(fields: EntryPassTokenFields): string {
  return [
    fields.entryPassId,
    fields.gameSessionId,
    fields.userId,
    String(fields.issuedAtMs),
    fields.version
  ].join("|");
}

export function buildEntryPassToken(
  fields: EntryPassTokenFields,
  secretValue: string
): string {
  return createHmac("sha256", secretValue)
    .update(serializeEntryPassTokenFields(fields))
    .digest("base64url");
}

export function hashEntryPassToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}
