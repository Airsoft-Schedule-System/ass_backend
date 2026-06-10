// api-spec §2.13 — 환불 요청 접수. 계좌번호는 AES-256-GCM 암호문만 저장한다.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, REFUND_ACCOUNT_KEY, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import {
  errAlreadyExists,
  errFailedPrecondition,
  errNotFound,
  errPermissionDenied
} from "../../lib/errors";
import { encryptRefundAccount } from "../../lib/crypto";
import { isParticipant, requireAuth } from "../../lib/permissions";
import {
  PARTICIPATION_STATUS,
  PAYMENT_SUBMISSION_STATUS,
  REFUND_STATUS
} from "../../lib/status";
import { asNonEmptyString, optionalString } from "../../lib/validation";
import type { GameSession, Participation } from "../../types/entities";
import type { RequestRefundOutput } from "../../types/functions";

export const requestRefund = onCall(
  { region: REGION, secrets: [REFUND_ACCOUNT_KEY] },
  async (request): Promise<RequestRefundOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const participationId = asNonEmptyString(data.participationId, "participationId");
    const bankName = asNonEmptyString(data.bankName, "bankName");
    const accountNumber = asNonEmptyString(data.accountNumber, "accountNumber");
    const accountHolder = asNonEmptyString(data.accountHolder, "accountHolder");
    const reason = optionalString(data.reason);

    const refundRequestId = await db.runTransaction(async (tx) => {
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
      const approvedPaymentSnap = await tx.get(
        db
          .collection(COLLECTIONS.PAYMENT_SUBMISSIONS)
          .where("participationId", "==", participationId)
          .where("status", "==", PAYMENT_SUBMISSION_STATUS.APPROVED)
          .limit(1)
      );
      const existingRefundSnap = await tx.get(
        db
          .collection(COLLECTIONS.REFUND_REQUESTS)
          .where("participationId", "==", participationId)
          .limit(1)
      );
      if (!sessionSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      const session = sessionSnap.data() as GameSession;

      if (!isParticipant(participation, uid)) {
        throw errPermissionDenied("본인 참가 신청만 환불을 요청할 수 있습니다");
      }
      if (participation.status !== PARTICIPATION_STATUS.CANCELLED) {
        throw errFailedPrecondition(
          `취소된 참가만 환불 요청할 수 있습니다 (현재: ${participation.status})`
        );
      }
      if (Date.now() >= session.cancelDeadline.toMillis()) {
        throw errFailedPrecondition("환불 요청 가능 시간이 지났습니다");
      }
      if (approvedPaymentSnap.empty) {
        throw errFailedPrecondition("확인된 입금 내역이 있어야 환불 요청할 수 있습니다");
      }
      if (!existingRefundSnap.empty) {
        throw errAlreadyExists("이미 환불 요청이 접수되었습니다");
      }

      const refundRef = db.collection(COLLECTIONS.REFUND_REQUESTS).doc();
      tx.set(refundRef, {
        participationId,
        gameSessionId: participation.gameSessionId,
        userId: uid,
        bankName,
        accountNumber: encryptRefundAccount(accountNumber, REFUND_ACCOUNT_KEY.value()),
        accountHolder,
        reason,
        status: REFUND_STATUS.REQUESTED,
        requestedAt: FieldValue.serverTimestamp(),
        processedBy: null,
        processedAt: null,
        note: null
      });
      tx.update(participationRef, {
        status: PARTICIPATION_STATUS.REFUND_REQUESTED,
        updatedAt: FieldValue.serverTimestamp()
      });

      return refundRef.id;
    });

    return { success: true, refundRequestId };
  }
);
