// api-spec §2.6a — 운영자 자기 게임 참가. A7: 승인·결제 없이 자동 확정.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errAlreadyExists, errNotFound } from "../../lib/errors";
import {
  assertCapacityAvailable,
  assertSessionStatusAllows,
  reachesCapacityAfterIncrement
} from "../../lib/guards";
import { assertSessionOwner, requireAuth } from "../../lib/permissions";
import { PARTICIPATION_STATUS, SESSION_STATUS } from "../../lib/status";
import { asNonEmptyString, assertProfileComplete } from "../../lib/validation";
import type { GameSession, User } from "../../types/entities";
import type { JoinAsOperatorOutput } from "../../types/functions";

export const joinAsOperator = onCall(
  { region: REGION },
  async (request): Promise<JoinAsOperatorOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const gameSessionId = asNonEmptyString(data.gameSessionId, "gameSessionId");

    // B1-6: 운영자도 실제 참가자로 남기므로 프로필 필수값을 동일하게 검증한다.
    const userSnap = await db.collection(COLLECTIONS.USERS).doc(uid).get();
    if (!userSnap.exists) throw errNotFound("사용자 프로필이 없습니다");
    assertProfileComplete(userSnap.data() as User);

    const participationId = await db.runTransaction(async (tx) => {
      const sessionRef = db.collection(COLLECTIONS.GAME_SESSIONS).doc(gameSessionId);
      const sessionSnap = await tx.get(sessionRef);
      if (!sessionSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      const session = sessionSnap.data() as GameSession;

      assertSessionOwner(session, uid);
      assertSessionStatusAllows("joinAsOperator", session);

      const dupSnap = await tx.get(
        db
          .collection(COLLECTIONS.PARTICIPATIONS)
          .where("gameSessionId", "==", gameSessionId)
          .where("userId", "==", uid)
          .limit(1)
      );
      if (!dupSnap.empty) throw errAlreadyExists("이미 신청한 세션입니다");

      assertCapacityAvailable(session);

      const participationRef = db.collection(COLLECTIONS.PARTICIPATIONS).doc();
      tx.set(participationRef, {
        gameSessionId,
        userId: uid,
        status: PARTICIPATION_STATUS.CONFIRMED,
        gameStartsAt: session.startsAt,
        // EntryPass 발급은 후속 onParticipationConfirmed 트리거의 단일 책임으로 둔다.
        entryPassId: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp()
      });

      const sessionUpdate: Record<string, unknown> = {
        confirmedCount: FieldValue.increment(1),
        updatedAt: FieldValue.serverTimestamp()
      };
      if (
        reachesCapacityAfterIncrement(session) &&
        session.status === SESSION_STATUS.RECRUITING
      ) {
        sessionUpdate.status = SESSION_STATUS.CLOSED;
      }
      tx.update(sessionRef, sessionUpdate);

      return participationRef.id;
    });

    return { success: true, participationId, status: "confirmed" };
  }
);
