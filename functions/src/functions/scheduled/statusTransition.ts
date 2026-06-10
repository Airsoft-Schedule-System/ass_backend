// api-spec §2.5 — 세션 상태 자동 전이. 세션별 개별 tx로 멱등 처리한다.
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { nextSessionStatus } from "../../lib/policy";
import { SESSION_STATUS } from "../../lib/status";
import type { GameSession } from "../../types/entities";
import type { GameSessionStatus } from "../../types/status";

function toPolicyView(session: GameSession): {
  status: GameSessionStatus;
  confirmedCount: number;
  capacity: number;
  startsAtMs: number;
  endsAtMs: number | null;
} {
  return {
    status: session.status,
    confirmedCount: session.confirmedCount,
    capacity: session.capacity,
    startsAtMs: session.startsAt.toMillis(),
    endsAtMs: session.endsAt ? session.endsAt.toMillis() : null
  };
}

export const scheduledStatusTransition = onSchedule(
  { schedule: "every 1 hours", timeZone: "Asia/Seoul", region: REGION },
  async () => {
    const now = Timestamp.now();
    const nowMs = now.toMillis();
    const candidates = new Map<string, GameSessionStatus>();

    const recruitingSnap = await db
      .collection(COLLECTIONS.GAME_SESSIONS)
      .where("status", "==", SESSION_STATUS.RECRUITING)
      .get();
    for (const doc of recruitingSnap.docs) {
      const session = doc.data() as GameSession;
      if (nextSessionStatus(toPolicyView(session), nowMs) === SESSION_STATUS.CLOSED) {
        candidates.set(doc.id, SESSION_STATUS.CLOSED);
      }
    }

    for (const status of [SESSION_STATUS.RECRUITING, SESSION_STATUS.CLOSED]) {
      const startsAtSnap = await db
        .collection(COLLECTIONS.GAME_SESSIONS)
        .where("status", "==", status)
        .where("startsAt", "<=", now)
        .get();
      for (const doc of startsAtSnap.docs) {
        if (candidates.has(doc.id)) continue;
        const session = doc.data() as GameSession;
        if (
          nextSessionStatus(toPolicyView(session), nowMs) ===
          SESSION_STATUS.IN_PROGRESS
        ) {
          candidates.set(doc.id, SESSION_STATUS.IN_PROGRESS);
        }
      }
    }

    const inProgressSnap = await db
      .collection(COLLECTIONS.GAME_SESSIONS)
      .where("status", "==", SESSION_STATUS.IN_PROGRESS)
      .get();
    for (const doc of inProgressSnap.docs) {
      const session = doc.data() as GameSession;
      if (
        nextSessionStatus(toPolicyView(session), nowMs) === SESSION_STATUS.COMPLETED
      ) {
        candidates.set(doc.id, SESSION_STATUS.COMPLETED);
      }
    }

    await Promise.all(
      [...candidates.entries()].map(async ([gameSessionId, expectedStatus]) => {
        try {
          await db.runTransaction(async (tx) => {
            const sessionRef = db
              .collection(COLLECTIONS.GAME_SESSIONS)
              .doc(gameSessionId);
            const sessionSnap = await tx.get(sessionRef);
            if (!sessionSnap.exists) return;

            const session = sessionSnap.data() as GameSession;
            const nextStatus = nextSessionStatus(toPolicyView(session), nowMs);
            if (nextStatus !== expectedStatus) return;

            tx.update(sessionRef, {
              status: nextStatus,
              updatedAt: FieldValue.serverTimestamp()
            });
          });
        } catch (error) {
          console.error("scheduledStatusTransition failed", {
            gameSessionId,
            error
          });
        }
      })
    );
  }
);
