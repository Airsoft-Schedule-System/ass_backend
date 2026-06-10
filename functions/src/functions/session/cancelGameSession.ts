// api-spec §2.4 — 게임 세션 취소. MVP 정원 규모에서는 tx 500 write 한도 내 처리한다.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errNotFound } from "../../lib/errors";
import { assertSessionStatusAllows } from "../../lib/guards";
import { assertSessionOwner, requireAuth } from "../../lib/permissions";
import { ENTRY_PASS_STATUS, PARTICIPATION_STATUS, SESSION_STATUS } from "../../lib/status";
import { asNonEmptyString, optionalString } from "../../lib/validation";
import { notifier, type NotificationEnvelope } from "../../notifications/notifier";
import type { GameSession, Participation } from "../../types/entities";
import type { CancelGameSessionOutput } from "../../types/functions";

const PRE_TERMINAL_PARTICIPATION_STATUS = [
  PARTICIPATION_STATUS.PENDING_APPROVAL,
  PARTICIPATION_STATUS.AWAITING_PAYMENT,
  PARTICIPATION_STATUS.PAYMENT_REVIEW,
  PARTICIPATION_STATUS.CONFIRMED
] as const;

export const cancelGameSession = onCall(
  { region: REGION },
  async (request): Promise<CancelGameSessionOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const gameSessionId = asNonEmptyString(data.gameSessionId, "gameSessionId");
    const reason = optionalString(data.reason);

    const result = await db.runTransaction(async (tx) => {
      const sessionRef = db.collection(COLLECTIONS.GAME_SESSIONS).doc(gameSessionId);
      const sessionSnap = await tx.get(sessionRef);
      if (!sessionSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      const session = sessionSnap.data() as GameSession;

      assertSessionOwner(session, uid);
      assertSessionStatusAllows("cancelGameSession", session);

      const participationsSnap = await tx.get(
        db
          .collection(COLLECTIONS.PARTICIPATIONS)
          .where("gameSessionId", "==", gameSessionId)
          .where("status", "in", [...PRE_TERMINAL_PARTICIPATION_STATUS])
      );
      const entryPassesSnap = await tx.get(
        db
          .collection(COLLECTIONS.ENTRY_PASSES)
          .where("gameSessionId", "==", gameSessionId)
          .where("status", "==", ENTRY_PASS_STATUS.ACTIVE)
      );

      tx.update(sessionRef, {
        status: SESSION_STATUS.CANCELLED,
        updatedAt: FieldValue.serverTimestamp()
      });
      for (const doc of participationsSnap.docs) {
        tx.update(doc.ref, {
          status: PARTICIPATION_STATUS.CANCELLED,
          updatedAt: FieldValue.serverTimestamp()
        });
      }
      for (const doc of entryPassesSnap.docs) {
        tx.update(doc.ref, {
          status: ENTRY_PASS_STATUS.REVOKED
        });
      }

      return {
        affectedParticipations: participationsSnap.size,
        participations: participationsSnap.docs.map((doc) => ({
          id: doc.id,
          data: doc.data() as Participation
        })),
        title: session.title
      };
    });

    const envelopes: NotificationEnvelope[] = result.participations.map((p) => {
      const notificationData: Record<string, string> = { type: "cancelled" };
      if (reason) notificationData.reason = reason;

      return {
        type: "session.changed",
        userId: p.data.userId,
        title: "게임 세션이 취소되었습니다",
        body: reason
          ? `${result.title} 세션이 취소되었습니다. ${reason}`
          : `${result.title} 세션이 취소되었습니다`,
        actionUrl: `/sessions/${gameSessionId}`,
        gameSessionId,
        participationId: p.id,
        data: notificationData
      };
    });
    await notifier.sendMany(envelopes);

    return {
      success: true,
      affectedParticipations: result.affectedParticipations
    };
  }
);
