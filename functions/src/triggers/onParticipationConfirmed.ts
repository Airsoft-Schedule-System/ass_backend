// api-spec §2.15 — confirmed 전이 시 QR EntryPass 발급.
// A7: joinAsOperator는 생성 시점부터 confirmed라 onDocumentUpdated가 발화하지 않는다.
// 운영자 자기 참가는 EntryPass 없이 markAttendance 수동 출석 경로로 처리한다.
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { REGION, QR_HMAC_SECRET, db } from "../config/runtime";
import { COLLECTIONS } from "../lib/collections";
import { buildEntryPassToken, hashEntryPassToken, QR_SECRET_VERSION } from "../lib/qr";
import { ENTRY_PASS_STATUS, PARTICIPATION_STATUS } from "../lib/status";
import type { EntryPass, GameSession, Participation } from "../types/entities";

const DAY_MS = 24 * 60 * 60 * 1000;

export const onParticipationConfirmed = onDocumentUpdated(
  {
    document: "participations/{participationId}",
    region: REGION,
    secrets: [QR_HMAC_SECRET]
  },
  async (event) => {
    const before = event.data?.before.data() as Participation | undefined;
    const after = event.data?.after.data() as Participation | undefined;
    if (!before || !after) return;
    if (
      before.status === PARTICIPATION_STATUS.CONFIRMED ||
      after.status !== PARTICIPATION_STATUS.CONFIRMED
    ) {
      return;
    }

    const participationId = event.params.participationId;
    const secretValue = QR_HMAC_SECRET.value();

    await db.runTransaction(async (tx) => {
      const participationRef = db
        .collection(COLLECTIONS.PARTICIPATIONS)
        .doc(participationId);
      const participationSnap = await tx.get(participationRef);
      if (!participationSnap.exists) {
        console.error("onParticipationConfirmed participation missing", {
          participationId
        });
        return;
      }

      const participation = participationSnap.data() as Participation;
      if (participation.status !== PARTICIPATION_STATUS.CONFIRMED) return;

      const activePassSnap = await tx.get(
        db
          .collection(COLLECTIONS.ENTRY_PASSES)
          .where("participationId", "==", participationId)
          .where("status", "==", ENTRY_PASS_STATUS.ACTIVE)
          .limit(1)
      );
      if (!activePassSnap.empty) return;

      const sessionRef = db
        .collection(COLLECTIONS.GAME_SESSIONS)
        .doc(participation.gameSessionId);
      const sessionSnap = await tx.get(sessionRef);
      if (!sessionSnap.exists) {
        console.error("onParticipationConfirmed session missing", {
          participationId,
          gameSessionId: participation.gameSessionId
        });
        return;
      }

      const session = sessionSnap.data() as GameSession;
      const entryPassRef = db.collection(COLLECTIONS.ENTRY_PASSES).doc();
      const issuedAt = Timestamp.now();
      const token = buildEntryPassToken(
        {
          entryPassId: entryPassRef.id,
          gameSessionId: participation.gameSessionId,
          userId: participation.userId,
          issuedAtMs: issuedAt.toMillis(),
          version: QR_SECRET_VERSION
        },
        secretValue
      );

      const entryPass: EntryPass = {
        participationId,
        gameSessionId: participation.gameSessionId,
        userId: participation.userId,
        status: ENTRY_PASS_STATUS.ACTIVE,
        qrTokenHash: hashEntryPassToken(token),
        qrSecretVersion: QR_SECRET_VERSION,
        issuedAt,
        expiresAt: Timestamp.fromMillis(session.startsAt.toMillis() + DAY_MS),
        usedAt: null,
        scannedBy: null
      };

      tx.set(entryPassRef, entryPass);
      tx.update(participationRef, {
        entryPassId: entryPassRef.id,
        updatedAt: FieldValue.serverTimestamp()
      });
    });
  }
);
