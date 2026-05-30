// api-spec §2.6 — 참가 신청. B1-6 프로필 검증 + 본인세션 금지 + 중복 금지.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errAlreadyExists, errFailedPrecondition, errNotFound } from "../../lib/errors";
import { assertSessionStatusAllows } from "../../lib/guards";
import { isSessionOwner, requireAuth } from "../../lib/permissions";
import { PARTICIPATION_STATUS } from "../../lib/status";
import { asNonEmptyString, assertProfileComplete } from "../../lib/validation";
import type { GameSession, User } from "../../types/entities";
import type { RequestParticipationOutput } from "../../types/functions";

export const requestParticipation = onCall(
  { region: REGION },
  async (request): Promise<RequestParticipationOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const gameSessionId = asNonEmptyString(data.gameSessionId, "gameSessionId");

    // B1-6: 프로필 필수값(닉네임) 서버 검증
    const userSnap = await db.collection(COLLECTIONS.USERS).doc(uid).get();
    if (!userSnap.exists) throw errNotFound("사용자 프로필이 없습니다");
    assertProfileComplete(userSnap.data() as User);

    const participationId = await db.runTransaction(async (tx) => {
      const sessionRef = db.collection(COLLECTIONS.GAME_SESSIONS).doc(gameSessionId);
      const sessionSnap = await tx.get(sessionRef);
      if (!sessionSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      const session = sessionSnap.data() as GameSession;

      assertSessionStatusAllows("requestParticipation", session); // recruiting만
      if (isSessionOwner(session, uid)) {
        throw errFailedPrecondition("본인이 만든 세션에는 신청할 수 없습니다");
      }

      const dupSnap = await tx.get(
        db
          .collection(COLLECTIONS.PARTICIPATIONS)
          .where("gameSessionId", "==", gameSessionId)
          .where("userId", "==", uid)
          .limit(1)
      );
      if (!dupSnap.empty) throw errAlreadyExists("이미 신청한 세션입니다");

      const ref = db.collection(COLLECTIONS.PARTICIPATIONS).doc();
      tx.set(ref, {
        gameSessionId,
        userId: uid,
        status: PARTICIPATION_STATUS.PENDING_APPROVAL,
        gameStartsAt: session.startsAt, // denormalized (ERD §5.7)
        entryPassId: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp()
      });
      return ref.id;
    });

    return { success: true, participationId, status: "pendingApproval" };
  }
);
