// api-spec §2.17a — 운영자 수동 출석 처리. A7 운영자 자기 참가는 EntryPass 없이 통과한다.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errFailedPrecondition, errNotFound } from "../../lib/errors";
import { assertSessionStatusAllows } from "../../lib/guards";
import { assertSessionOwner, requireAuth } from "../../lib/permissions";
import { ENTRY_PASS_STATUS, PARTICIPATION_STATUS } from "../../lib/status";
import { asNonEmptyString } from "../../lib/validation";
import type { EntryPass, GameSession, Participation } from "../../types/entities";
import type { MarkAttendanceOutput } from "../../types/functions";

export const markAttendance = onCall(
  { region: REGION },
  async (request): Promise<MarkAttendanceOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const participationId = asNonEmptyString(data.participationId, "participationId");

    await db.runTransaction(async (tx) => {
      const participationRef = db
        .collection(COLLECTIONS.PARTICIPATIONS)
        .doc(participationId);
      const participationSnap = await tx.get(participationRef);
      if (!participationSnap.exists) throw errNotFound("참가 신청을 찾을 수 없습니다");
      const participation = participationSnap.data() as Participation;

      const sessionRef = db
        .collection(COLLECTIONS.GAME_SESSIONS)
        .doc(participation.gameSessionId);
      const entryPassRef =
        participation.entryPassId != null
          ? db.collection(COLLECTIONS.ENTRY_PASSES).doc(participation.entryPassId)
          : null;
      const [sessionSnap, entryPassSnap] = await Promise.all([
        tx.get(sessionRef),
        entryPassRef ? tx.get(entryPassRef) : Promise.resolve(null)
      ]);

      if (!sessionSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      const session = sessionSnap.data() as GameSession;
      const entryPass =
        entryPassSnap && entryPassSnap.exists
          ? (entryPassSnap.data() as EntryPass)
          : null;
      const now = Timestamp.now();

      assertSessionOwner(session, uid);
      assertSessionStatusAllows("markAttendance", session);
      if (participation.status !== PARTICIPATION_STATUS.CONFIRMED) {
        throw errFailedPrecondition(
          `출석 처리 가능한 참가 상태가 아닙니다 (현재: ${participation.status})`
        );
      }

      tx.update(participationRef, {
        status: PARTICIPATION_STATUS.ATTENDED,
        updatedAt: FieldValue.serverTimestamp()
      });

      // EntryPass가 없는 A7 운영자 자기 참가 경로는 이 단계를 건너뛴다.
      if (entryPassRef && entryPass?.status === ENTRY_PASS_STATUS.ACTIVE) {
        tx.update(entryPassRef, {
          status: ENTRY_PASS_STATUS.USED,
          usedAt: now,
          scannedBy: uid
        });
      }
    });

    return { success: true };
  }
);
