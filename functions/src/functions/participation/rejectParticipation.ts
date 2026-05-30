// api-spec §2.8 — 참가 거절. B1-2 세션상태 가드 + B3-1 권한. 거절 사유는 FCM으로만 전달(ERD §5.7에 필드 없음).
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errFailedPrecondition, errNotFound } from "../../lib/errors";
import { assertSessionStatusAllows } from "../../lib/guards";
import { assertSessionOwner, requireAuth } from "../../lib/permissions";
import { PARTICIPATION_STATUS } from "../../lib/status";
import { asNonEmptyString, optionalString } from "../../lib/validation";
import { notifier, type NotificationEnvelope } from "../../notifications/notifier";
import type { GameSession, Participation } from "../../types/entities";
import type { RejectParticipationOutput } from "../../types/functions";

export const rejectParticipation = onCall(
  { region: REGION },
  async (request): Promise<RejectParticipationOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const participationId = asNonEmptyString(data.participationId, "participationId");
    const reason = optionalString(data.reason);

    const ctx = await db.runTransaction(async (tx) => {
      const pRef = db.collection(COLLECTIONS.PARTICIPATIONS).doc(participationId);
      const pSnap = await tx.get(pRef);
      if (!pSnap.exists) throw errNotFound("참가 신청을 찾을 수 없습니다");
      const participation = pSnap.data() as Participation;

      const sRef = db
        .collection(COLLECTIONS.GAME_SESSIONS)
        .doc(participation.gameSessionId);
      const sSnap = await tx.get(sRef);
      if (!sSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      const session = sSnap.data() as GameSession;

      assertSessionOwner(session, uid); // B3-1
      assertSessionStatusAllows("rejectParticipation", session); // B1-2
      if (participation.status !== PARTICIPATION_STATUS.PENDING_APPROVAL) {
        throw errFailedPrecondition(
          `승인 대기(pendingApproval) 상태가 아닙니다 (현재: ${participation.status})`
        );
      }

      tx.update(pRef, {
        status: PARTICIPATION_STATUS.REJECTED,
        updatedAt: FieldValue.serverTimestamp()
      });

      return {
        userId: participation.userId,
        gameSessionId: participation.gameSessionId,
        gameTitle: session.title
      };
    });

    const body = reason
      ? `${ctx.gameTitle} 참가 신청이 거절되었습니다. ${reason}`
      : `${ctx.gameTitle} 참가 신청이 거절되었습니다`;
    const envelope: NotificationEnvelope = {
      type: "participation.decision",
      userId: ctx.userId,
      title: "참가 신청이 거절되었습니다",
      body,
      actionUrl: `/participations/${participationId}`,
      gameSessionId: ctx.gameSessionId,
      participationId,
      data: reason ? { decision: "rejected", reason } : { decision: "rejected" }
    };
    await notifier.send(envelope);

    return { success: true };
  }
);
