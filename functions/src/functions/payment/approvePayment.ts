// api-spec §2.11 / §5.6.1 — 입금 확인. B1-1 정원 가드 flagship + B1-2 세션상태 가드 + B3-1 권한.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errFailedPrecondition, errNotFound } from "../../lib/errors";
import {
  assertCapacityAvailable,
  assertSessionStatusAllows,
  reachesCapacityAfterIncrement
} from "../../lib/guards";
import { assertSessionOwner, requireAuth } from "../../lib/permissions";
import {
  PARTICIPATION_STATUS,
  PAYMENT_SUBMISSION_STATUS,
  SESSION_STATUS
} from "../../lib/status";
import { asNonEmptyString } from "../../lib/validation";
import { notifier, type NotificationEnvelope } from "../../notifications/notifier";
import type {
  GameSession,
  Participation,
  PaymentSubmission
} from "../../types/entities";
import type { ApprovePaymentOutput } from "../../types/functions";

export const approvePayment = onCall(
  { region: REGION },
  async (request): Promise<ApprovePaymentOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const paymentSubmissionId = asNonEmptyString(
      data.paymentSubmissionId,
      "paymentSubmissionId"
    );

    const result = await db.runTransaction(async (tx) => {
      const subRef = db
        .collection(COLLECTIONS.PAYMENT_SUBMISSIONS)
        .doc(paymentSubmissionId);
      const subSnap = await tx.get(subRef);
      if (!subSnap.exists) throw errNotFound("송금증을 찾을 수 없습니다");
      const submission = subSnap.data() as PaymentSubmission;

      const pRef = db
        .collection(COLLECTIONS.PARTICIPATIONS)
        .doc(submission.participationId);
      const sRef = db
        .collection(COLLECTIONS.GAME_SESSIONS)
        .doc(submission.gameSessionId);
      const [pSnap, sSnap] = await Promise.all([tx.get(pRef), tx.get(sRef)]);
      if (!pSnap.exists) throw errNotFound("참가 신청을 찾을 수 없습니다");
      if (!sSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      const participation = pSnap.data() as Participation;
      const session = sSnap.data() as GameSession;

      assertSessionOwner(session, uid); // B3-1
      assertSessionStatusAllows("approvePayment", session); // B1-2
      if (submission.status !== PAYMENT_SUBMISSION_STATUS.PENDING) {
        throw errFailedPrecondition(
          `확인 대기(pending) 상태가 아닙니다 (현재: ${submission.status})`
        );
      }
      if (participation.status !== PARTICIPATION_STATUS.PAYMENT_REVIEW) {
        throw errFailedPrecondition(
          `송금증 확인 단계(paymentReview)가 아닙니다 (현재: ${participation.status})`
        );
      }
      assertCapacityAvailable(session); // B1-1 ★ confirmedCount < capacity

      tx.update(subRef, {
        status: PAYMENT_SUBMISSION_STATUS.APPROVED,
        reviewedBy: uid,
        reviewedAt: FieldValue.serverTimestamp()
      });
      tx.update(pRef, {
        status: PARTICIPATION_STATUS.CONFIRMED,
        updatedAt: FieldValue.serverTimestamp()
      });
      const sessionUpdate: Record<string, unknown> = {
        confirmedCount: FieldValue.increment(1),
        updatedAt: FieldValue.serverTimestamp()
      };
      // 정원 도달 시 recruiting → closed (EntryPass는 onParticipationConfirmed 트리거 담당, 범위 외)
      if (
        reachesCapacityAfterIncrement(session) &&
        session.status === SESSION_STATUS.RECRUITING
      ) {
        sessionUpdate.status = SESSION_STATUS.CLOSED;
      }
      tx.update(sRef, sessionUpdate);

      return {
        userId: participation.userId,
        gameSessionId: submission.gameSessionId,
        participationId: submission.participationId,
        gameTitle: session.title
      };
    });

    const envelopes: NotificationEnvelope[] = [
      {
        type: "payment.decision",
        userId: result.userId,
        title: "송금증이 확인되었습니다",
        body: `${result.gameTitle} 송금증이 확인되었습니다`,
        actionUrl: `/participations/${result.participationId}/payment`,
        gameSessionId: result.gameSessionId,
        participationId: result.participationId,
        data: { decision: "approved" }
      },
      {
        type: "participation.confirmed",
        userId: result.userId,
        title: "참석이 확정되었습니다",
        body: `${result.gameTitle} 참석 확정! QR 입장권을 확인하세요`,
        actionUrl: `/participations/${result.participationId}/pass`,
        gameSessionId: result.gameSessionId,
        participationId: result.participationId
      }
    ];
    await notifier.sendMany(envelopes);

    return { success: true, participationId: result.participationId };
  }
);
