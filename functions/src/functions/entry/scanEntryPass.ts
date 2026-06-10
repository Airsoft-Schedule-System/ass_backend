// api-spec §2.17 — 세션 운영자 QR 스캔 출석 처리.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { REGION, QR_HMAC_SECRET, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errFailedPrecondition, errInvalidArgument, errNotFound } from "../../lib/errors";
import { assertSessionStatusAllows } from "../../lib/guards";
import { assertSessionOwner, requireAuth } from "../../lib/permissions";
import { hashEntryPassToken } from "../../lib/qr";
import { ENTRY_PASS_STATUS, PARTICIPATION_STATUS } from "../../lib/status";
import { asNonEmptyString } from "../../lib/validation";
import type { EntryPass, GameSession, Participation, User } from "../../types/entities";
import type { ScanEntryPassOutput } from "../../types/functions";

function readQrPayload(value: unknown): { entryPassId: string; token: string } {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    throw errInvalidArgument("qrPayload는 객체여야 합니다");
  }
  const payload = value as Record<string, unknown>;
  return {
    entryPassId: asNonEmptyString(payload.entryPassId, "qrPayload.entryPassId"),
    token: asNonEmptyString(payload.token, "qrPayload.token")
  };
}

export const scanEntryPass = onCall(
  { region: REGION, secrets: [QR_HMAC_SECRET] },
  async (request): Promise<ScanEntryPassOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const qrPayload = readQrPayload(data.qrPayload);

    return db.runTransaction(async (tx) => {
      const entryPassRef = db
        .collection(COLLECTIONS.ENTRY_PASSES)
        .doc(qrPayload.entryPassId);
      const entryPassSnap = await tx.get(entryPassRef);
      if (!entryPassSnap.exists) throw errNotFound("입장권을 찾을 수 없습니다");
      const entryPass = entryPassSnap.data() as EntryPass;

      const participationRef = db
        .collection(COLLECTIONS.PARTICIPATIONS)
        .doc(entryPass.participationId);
      const sessionRef = db
        .collection(COLLECTIONS.GAME_SESSIONS)
        .doc(entryPass.gameSessionId);
      const userRef = db.collection(COLLECTIONS.USERS).doc(entryPass.userId);
      const [participationSnap, sessionSnap, userSnap] = await Promise.all([
        tx.get(participationRef),
        tx.get(sessionRef),
        tx.get(userRef)
      ]);

      if (!participationSnap.exists) throw errNotFound("참가 신청을 찾을 수 없습니다");
      if (!sessionSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      if (!userSnap.exists) throw errNotFound("사용자 프로필이 없습니다");

      const participation = participationSnap.data() as Participation;
      const session = sessionSnap.data() as GameSession;
      const user = userSnap.data() as User;
      const now = Timestamp.now();

      assertSessionOwner(session, uid);
      assertSessionStatusAllows("scanEntryPass", session);
      if (hashEntryPassToken(qrPayload.token) !== entryPass.qrTokenHash) {
        throw errFailedPrecondition("유효하지 않은 QR 코드입니다");
      }
      if (entryPass.status !== ENTRY_PASS_STATUS.ACTIVE) {
        throw errFailedPrecondition("사용 가능한 입장권이 아닙니다");
      }
      if (entryPass.expiresAt.toMillis() <= now.toMillis()) {
        throw errFailedPrecondition("입장권이 만료되었습니다");
      }
      if (participation.status !== PARTICIPATION_STATUS.CONFIRMED) {
        throw errFailedPrecondition(
          `출석 처리 가능한 참가 상태가 아닙니다 (현재: ${participation.status})`
        );
      }

      tx.update(entryPassRef, {
        status: ENTRY_PASS_STATUS.USED,
        usedAt: now,
        scannedBy: uid
      });
      tx.update(participationRef, {
        status: PARTICIPATION_STATUS.ATTENDED,
        updatedAt: FieldValue.serverTimestamp()
      });

      return {
        success: true,
        userId: entryPass.userId,
        displayName: user.displayName
      };
    });
  }
);
