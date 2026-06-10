// api-spec §2.16 — 저장 필드로 QR 토큰을 재계산해 반환한다. 쓰기는 없다.
import { onCall } from "firebase-functions/v2/https";
import { REGION, QR_HMAC_SECRET, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errFailedPrecondition, errNotFound } from "../../lib/errors";
import { buildEntryPassToken } from "../../lib/qr";
import { requireAuth } from "../../lib/permissions";
import { ENTRY_PASS_STATUS, PARTICIPATION_STATUS } from "../../lib/status";
import { asNonEmptyString } from "../../lib/validation";
import type { EntryPass, Participation } from "../../types/entities";
import type { GetEntryPassTokenOutput } from "../../types/functions";

export const getEntryPassToken = onCall(
  { region: REGION, secrets: [QR_HMAC_SECRET] },
  async (request): Promise<GetEntryPassTokenOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const gameSessionId = asNonEmptyString(data.gameSessionId, "gameSessionId");

    const participationSnap = await db
      .collection(COLLECTIONS.PARTICIPATIONS)
      .where("gameSessionId", "==", gameSessionId)
      .where("userId", "==", uid)
      .limit(1)
      .get();
    if (participationSnap.empty) throw errNotFound("참가 신청을 찾을 수 없습니다");

    const participation = participationSnap.docs[0].data() as Participation;
    if (participation.status !== PARTICIPATION_STATUS.CONFIRMED) {
      throw errFailedPrecondition("확정된 참가자만 입장권을 조회할 수 있습니다");
    }
    if (participation.entryPassId == null) {
      throw errFailedPrecondition("입장권이 아직 발급되지 않았습니다");
    }

    const entryPassSnap = await db
      .collection(COLLECTIONS.ENTRY_PASSES)
      .doc(participation.entryPassId)
      .get();
    if (!entryPassSnap.exists) throw errNotFound("입장권을 찾을 수 없습니다");

    const entryPass = entryPassSnap.data() as EntryPass;
    if (
      entryPass.userId !== uid ||
      entryPass.gameSessionId !== gameSessionId ||
      entryPass.participationId !== participationSnap.docs[0].id
    ) {
      throw errFailedPrecondition("입장권 정보가 참가 신청과 일치하지 않습니다");
    }
    if (entryPass.status !== ENTRY_PASS_STATUS.ACTIVE) {
      throw errFailedPrecondition("사용 가능한 입장권이 아닙니다");
    }
    if (entryPass.expiresAt.toMillis() <= Date.now()) {
      throw errFailedPrecondition("입장권이 만료되었습니다");
    }

    const token = buildEntryPassToken(
      {
        entryPassId: entryPassSnap.id,
        gameSessionId: entryPass.gameSessionId,
        userId: entryPass.userId,
        issuedAtMs: entryPass.issuedAt.toMillis(),
        version: entryPass.qrSecretVersion
      },
      QR_HMAC_SECRET.value()
    );

    return {
      entryPassId: entryPassSnap.id,
      token,
      expiresAt: entryPass.expiresAt
    };
  }
);
