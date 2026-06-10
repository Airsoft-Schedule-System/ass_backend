// api-spec §2.10 — 송금증 제출. Storage 업로더 본인 검증은 후속 getReceiptUrl에서 보강한다.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import {
  errFailedPrecondition,
  errInvalidArgument,
  errNotFound,
  errPermissionDenied
} from "../../lib/errors";
import { assertSessionStatusAllows } from "../../lib/guards";
import { isParticipant, requireAuth } from "../../lib/permissions";
import { isPreTransfer } from "../../lib/seams";
import { PARTICIPATION_STATUS, PAYMENT_SUBMISSION_STATUS } from "../../lib/status";
import { asNonEmptyString } from "../../lib/validation";
import type { GameSession, Participation } from "../../types/entities";
import type { SubmitPaymentOutput } from "../../types/functions";

export const submitPayment = onCall(
  { region: REGION },
  async (request): Promise<SubmitPaymentOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const participationId = asNonEmptyString(data.participationId, "participationId");
    const senderName = asNonEmptyString(data.senderName, "senderName");
    const receiptImageUrl = asNonEmptyString(data.receiptImageUrl, "receiptImageUrl");

    if (typeof data.amount !== "number" || Number.isNaN(data.amount)) {
      throw errInvalidArgument("amount는 숫자여야 합니다");
    }
    if (!receiptImageUrl.startsWith("paymentReceipts/")) {
      throw errInvalidArgument("receiptImageUrl은 paymentReceipts/ 경로여야 합니다");
    }

    const paymentSubmissionId = await db.runTransaction(async (tx) => {
      const participationRef = db
        .collection(COLLECTIONS.PARTICIPATIONS)
        .doc(participationId);
      const participationSnap = await tx.get(participationRef);
      if (!participationSnap.exists) throw errNotFound("참가 신청을 찾을 수 없습니다");
      const participation = participationSnap.data() as Participation;

      const sessionRef = db
        .collection(COLLECTIONS.GAME_SESSIONS)
        .doc(participation.gameSessionId);
      const sessionSnap = await tx.get(sessionRef);
      if (!sessionSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      const session = sessionSnap.data() as GameSession;

      if (!isParticipant(participation, uid)) {
        throw errPermissionDenied("본인 참가 신청에만 송금증을 제출할 수 있습니다");
      }
      assertSessionStatusAllows("submitPayment", session);
      if (!isPreTransfer(session.paymentMethod)) {
        throw errFailedPrecondition("선입금 세션에만 송금증을 제출할 수 있습니다");
      }
      if (participation.status !== PARTICIPATION_STATUS.AWAITING_PAYMENT) {
        throw errFailedPrecondition(
          `입금 대기(awaitingPayment) 상태가 아닙니다 (현재: ${participation.status})`
        );
      }
      if (data.amount !== session.gameFee) {
        throw errFailedPrecondition("입금 금액이 게임비와 일치하지 않습니다");
      }

      const submissionRef = db.collection(COLLECTIONS.PAYMENT_SUBMISSIONS).doc();
      tx.set(submissionRef, {
        participationId,
        gameSessionId: participation.gameSessionId,
        userId: uid,
        senderName,
        amount: data.amount,
        receiptImageUrl,
        status: PAYMENT_SUBMISSION_STATUS.PENDING,
        submittedAt: FieldValue.serverTimestamp(),
        reviewedBy: null,
        reviewedAt: null,
        rejectionReason: null
      });
      tx.update(participationRef, {
        status: PARTICIPATION_STATUS.PAYMENT_REVIEW,
        updatedAt: FieldValue.serverTimestamp()
      });

      return submissionRef.id;
    });

    return { success: true, paymentSubmissionId };
  }
);
