// api-spec §2.7 — 참가 승인. B1-2 세션상태 가드 + B3-1 권한. FCM: participation.decision + payment.requested.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errFailedPrecondition, errNotFound } from "../../lib/errors";
import { assertSessionStatusAllows } from "../../lib/guards";
import { assertSessionOwner, requireAuth } from "../../lib/permissions";
import { PARTICIPATION_STATUS } from "../../lib/status";
import { asNonEmptyString } from "../../lib/validation";
import { notifier, type NotificationEnvelope } from "../../notifications/notifier";
import type { GameSession, Participation } from "../../types/entities";
import type { ApproveParticipationOutput } from "../../types/functions";

export const approveParticipation = onCall(
  { region: REGION },
  async (request): Promise<ApproveParticipationOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const participationId = asNonEmptyString(data.participationId, "participationId");

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
      assertSessionStatusAllows("approveParticipation", session); // B1-2
      if (participation.status !== PARTICIPATION_STATUS.PENDING_APPROVAL) {
        throw errFailedPrecondition(
          `승인 대기(pendingApproval) 상태가 아닙니다 (현재: ${participation.status})`
        );
      }

      tx.update(pRef, {
        status: PARTICIPATION_STATUS.AWAITING_PAYMENT,
        updatedAt: FieldValue.serverTimestamp()
      });

      return { participation, session };
    });

    const title = ctx.session.title;
    const envelopes: NotificationEnvelope[] = [
      {
        type: "participation.decision",
        userId: ctx.participation.userId,
        title: "참가 신청이 승인되었습니다",
        body: `${title} 참가 신청이 승인되었습니다. 입금 안내를 확인하세요`,
        actionUrl: `/participations/${participationId}`,
        gameSessionId: ctx.participation.gameSessionId,
        participationId,
        data: { decision: "approved" }
      },
      {
        type: "payment.requested",
        userId: ctx.participation.userId,
        title: "입금 안내",
        body: `${title} 게임비 ${ctx.session.gameFee}원을 입금해주세요`,
        actionUrl: `/participations/${participationId}/payment`,
        gameSessionId: ctx.participation.gameSessionId,
        participationId,
        data: {
          bankName: ctx.session.bankAccount.bankName,
          accountNumber: ctx.session.bankAccount.accountNumber,
          accountHolder: ctx.session.bankAccount.accountHolder,
          gameFee: String(ctx.session.gameFee),
          cancelDeadline: ctx.session.cancelDeadline.toDate().toISOString()
        }
      }
    ];
    await notifier.sendMany(envelopes);

    return { success: true, newStatus: "awaitingPayment" };
  }
);
