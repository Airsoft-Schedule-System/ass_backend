// api-spec §2.12 — 송금증 반려. B1-2 세션상태 가드 + B3-1 권한. submission→rejected, participation→awaitingPayment(재제출).
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errFailedPrecondition, errNotFound } from "../../lib/errors";
import { assertSessionStatusAllows } from "../../lib/guards";
import { assertSessionOwner, requireAuth } from "../../lib/permissions";
import { PARTICIPATION_STATUS, PAYMENT_SUBMISSION_STATUS } from "../../lib/status";
import { asNonEmptyString } from "../../lib/validation";
import { notifier, type NotificationEnvelope } from "../../notifications/notifier";
import type { GameSession, PaymentSubmission } from "../../types/entities";
import type { RejectPaymentOutput } from "../../types/functions";

export const rejectPayment = onCall(
  { region: REGION },
  async (request): Promise<RejectPaymentOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const paymentSubmissionId = asNonEmptyString(
      data.paymentSubmissionId,
      "paymentSubmissionId"
    );
    const reason = asNonEmptyString(data.reason, "reason"); // §2.12 reason 필수

    const ctx = await db.runTransaction(async (tx) => {
      const subRef = db
        .collection(COLLECTIONS.PAYMENT_SUBMISSIONS)
        .doc(paymentSubmissionId);
      const subSnap = await tx.get(subRef);
      if (!subSnap.exists) throw errNotFound("송금증을 찾을 수 없습니다");
      const submission = subSnap.data() as PaymentSubmission;

      const sRef = db
        .collection(COLLECTIONS.GAME_SESSIONS)
        .doc(submission.gameSessionId);
      const pRef = db
        .collection(COLLECTIONS.PARTICIPATIONS)
        .doc(submission.participationId);
      const [sSnap, pSnap] = await Promise.all([tx.get(sRef), tx.get(pRef)]);
      if (!sSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      if (!pSnap.exists) throw errNotFound("참가 신청을 찾을 수 없습니다");
      const session = sSnap.data() as GameSession;

      assertSessionOwner(session, uid); // B3-1
      assertSessionStatusAllows("rejectPayment", session); // B1-2
      if (submission.status !== PAYMENT_SUBMISSION_STATUS.PENDING) {
        throw errFailedPrecondition(
          `확인 대기(pending) 상태가 아닙니다 (현재: ${submission.status})`
        );
      }

      tx.update(subRef, {
        status: PAYMENT_SUBMISSION_STATUS.REJECTED,
        rejectionReason: reason,
        reviewedBy: uid,
        reviewedAt: FieldValue.serverTimestamp()
      });
      tx.update(pRef, {
        status: PARTICIPATION_STATUS.AWAITING_PAYMENT,
        updatedAt: FieldValue.serverTimestamp()
      });

      return {
        userId: submission.userId,
        gameSessionId: submission.gameSessionId,
        participationId: submission.participationId
      };
    });

    const envelope: NotificationEnvelope = {
      type: "payment.decision",
      userId: ctx.userId,
      title: "송금증이 반려되었습니다",
      body: `${reason}. 다시 송금증을 첨부해주세요`,
      actionUrl: `/participations/${ctx.participationId}/payment`,
      gameSessionId: ctx.gameSessionId,
      participationId: ctx.participationId,
      data: { decision: "rejected", reason }
    };
    await notifier.send(envelope);

    return { success: true };
  }
);
