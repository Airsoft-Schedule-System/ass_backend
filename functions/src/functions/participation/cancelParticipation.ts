// api-spec §2.9 — 참가 취소. 세션상태 가드 없이 참가 상태로만 제한한다.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errFailedPrecondition, errNotFound } from "../../lib/errors";
import { assertParticipantOrOwner, requireAuth } from "../../lib/permissions";
import {
  CANCELLABLE_PARTICIPATION_STATUS,
  isRefundEligible
} from "../../lib/policy";
import { ENTRY_PASS_STATUS, PARTICIPATION_STATUS, SESSION_STATUS } from "../../lib/status";
import { asNonEmptyString, optionalString } from "../../lib/validation";
import type { EntryPass, GameSession, Participation } from "../../types/entities";
import type { CancelParticipationOutput } from "../../types/functions";

export const cancelParticipation = onCall(
  { region: REGION },
  async (request): Promise<CancelParticipationOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const participationId = asNonEmptyString(data.participationId, "participationId");
    const _reason = optionalString(data.reason); // ERD §5.7에 저장 필드가 없어 수신만 한다.

    const refundEligible = await db.runTransaction(async (tx) => {
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

      const entryPassRef =
        participation.entryPassId != null
          ? db.collection(COLLECTIONS.ENTRY_PASSES).doc(participation.entryPassId)
          : null;
      const entryPassSnap = entryPassRef ? await tx.get(entryPassRef) : null;

      assertParticipantOrOwner(participation, session, uid);
      if (!CANCELLABLE_PARTICIPATION_STATUS.has(participation.status)) {
        throw errFailedPrecondition(
          `취소 가능한 참가 상태가 아닙니다 (현재: ${participation.status})`
        );
      }

      const eligible = isRefundEligible(
        participation.status,
        session.cancelDeadline.toMillis(),
        Date.now()
      );

      tx.update(participationRef, {
        status: PARTICIPATION_STATUS.CANCELLED,
        updatedAt: FieldValue.serverTimestamp()
      });

      if (participation.status === PARTICIPATION_STATUS.CONFIRMED) {
        const sessionUpdate: Record<string, unknown> = {
          confirmedCount: FieldValue.increment(-1),
          updatedAt: FieldValue.serverTimestamp()
        };
        if (session.status === SESSION_STATUS.CLOSED) {
          sessionUpdate.status = SESSION_STATUS.RECRUITING;
        }
        tx.update(sessionRef, sessionUpdate);
      }

      if (entryPassRef && entryPassSnap?.exists) {
        const entryPass = entryPassSnap.data() as EntryPass;
        if (entryPass.status === ENTRY_PASS_STATUS.ACTIVE) {
          tx.update(entryPassRef, {
            status: ENTRY_PASS_STATUS.REVOKED
          });
        }
      }

      return eligible;
    });

    return { success: true, refundEligible };
  }
);
