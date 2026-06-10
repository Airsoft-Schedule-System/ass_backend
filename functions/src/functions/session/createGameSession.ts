// api-spec §2.2 — 게임 세션 생성. 모든 로그인 사용자 가능(역할 없음). B1-6 프로필 검증 포함.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errInvalidArgument, errNotFound } from "../../lib/errors";
import { requireAuth } from "../../lib/permissions";
import { PAYMENT_METHOD, SESSION_STATUS } from "../../lib/status";
import { toTimestamp } from "../../lib/time";
import {
  asNonEmptyString,
  assertProfileComplete,
  optionalString,
  validateCreateGameSessionInput
} from "../../lib/validation";
import type { BankAccount } from "../../types/common";
import type { User } from "../../types/entities";
import type { CreateGameSessionOutput } from "../../types/functions";

// §10.3 cancelDeadline 기본값 = startsAt - 48h
const CANCEL_DEADLINE_OFFSET_MS = 48 * 60 * 60 * 1000;

function readBankAccount(value: unknown): BankAccount {
  if (!value || typeof value !== "object") {
    throw errInvalidArgument("bankAccount(bankName, accountNumber, accountHolder)는 필수입니다");
  }
  const o = value as Record<string, unknown>;
  return {
    bankName: asNonEmptyString(o.bankName, "bankAccount.bankName"),
    accountNumber: asNonEmptyString(o.accountNumber, "bankAccount.accountNumber"),
    accountHolder: asNonEmptyString(o.accountHolder, "bankAccount.accountHolder")
  };
}

export const createGameSession = onCall(
  { region: REGION },
  async (request): Promise<CreateGameSessionOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;

    // B1-6: 프로필 필수값(닉네임) 서버 검증
    const userSnap = await db.collection(COLLECTIONS.USERS).doc(uid).get();
    if (!userSnap.exists) throw errNotFound("사용자 프로필이 없습니다");
    assertProfileComplete(userSnap.data() as User);

    // 입력 검증 (fieldId XOR fieldName, capacity>0, gameFee>=0, presetId XOR customRules)
    validateCreateGameSessionInput(data);
    const bankAccount = readBankAccount(data.bankAccount);

    const startsAt = toTimestamp(data.startsAt, "startsAt");
    if (startsAt.toMillis() <= Date.now()) {
      throw errInvalidArgument("startsAt은 미래 시각이어야 합니다");
    }
    const endsAt = data.endsAt != null ? toTimestamp(data.endsAt, "endsAt") : null;
    const cancelDeadline =
      data.cancelDeadline != null
        ? toTimestamp(data.cancelDeadline, "cancelDeadline")
        : Timestamp.fromMillis(startsAt.toMillis() - CANCEL_DEADLINE_OFFSET_MS);

    const ref = db.collection(COLLECTIONS.GAME_SESSIONS).doc();
    await ref.set({
      title: asNonEmptyString(data.title, "title"),
      createdByUserId: uid,
      hostTeamId: optionalString(data.hostTeamId),
      fieldId: optionalString(data.fieldId),
      fieldName: optionalString(data.fieldName),
      startsAt,
      endsAt,
      capacity: data.capacity as number,
      confirmedCount: 0,
      gameFee: data.gameFee as number,
      paymentMethod: PAYMENT_METHOD.PRE_TRANSFER,
      bankAccount,
      presetId: optionalString(data.presetId),
      customRules:
        data.customRules && typeof data.customRules === "object"
          ? (data.customRules as Record<string, unknown>)
          : null,
      cancelDeadline,
      status: SESSION_STATUS.RECRUITING,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp()
    });

    return { success: true, gameSessionId: ref.id };
  }
);
