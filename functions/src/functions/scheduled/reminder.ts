// api-spec §2.18 — 게임 시작 24시간 전 안내 알림. 세션별 tx로 멱등 마킹한다.
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { isInReminderWindow } from "../../lib/policy";
import { PARTICIPATION_STATUS, SESSION_STATUS } from "../../lib/status";
import { notifier, type NotificationEnvelope } from "../../notifications/notifier";
import type { GameSession, Participation } from "../../types/entities";

const HALF_HOUR_MS = 30 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

const reminderDateFormatter = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul",
  dateStyle: "medium",
  timeStyle: "short"
});

function formatStartsAt(startsAt: Timestamp): string {
  return reminderDateFormatter.format(startsAt.toDate());
}

async function collectReminderCandidates(nowMs: number): Promise<string[]> {
  const lower = Timestamp.fromMillis(nowMs + DAY_MS - HALF_HOUR_MS);
  const upper = Timestamp.fromMillis(nowMs + DAY_MS + HALF_HOUR_MS);
  const candidates = new Map<string, GameSession>();

  for (const status of [SESSION_STATUS.RECRUITING, SESSION_STATUS.CLOSED]) {
    const snap = await db
      .collection(COLLECTIONS.GAME_SESSIONS)
      .where("status", "==", status)
      .where("startsAt", ">=", lower)
      .where("startsAt", "<=", upper)
      .get();

    for (const doc of snap.docs) {
      const session = doc.data() as GameSession;
      if (
        session.reminderSent !== true &&
        isInReminderWindow(session.startsAt.toMillis(), nowMs)
      ) {
        candidates.set(doc.id, session);
      }
    }
  }

  return [...candidates.keys()];
}

async function markReminderSent(gameSessionId: string, nowMs: number): Promise<GameSession | null> {
  return db.runTransaction(async (tx) => {
    const sessionRef = db.collection(COLLECTIONS.GAME_SESSIONS).doc(gameSessionId);
    const sessionSnap = await tx.get(sessionRef);
    if (!sessionSnap.exists) return null;

    const session = sessionSnap.data() as GameSession;
    if (session.reminderSent === true) return null;
    if (
      session.status !== SESSION_STATUS.RECRUITING &&
      session.status !== SESSION_STATUS.CLOSED
    ) {
      return null;
    }
    if (!isInReminderWindow(session.startsAt.toMillis(), nowMs)) return null;

    // 중복 푸시 방지를 위해 선마킹-후발신한다. 크래시 시 해당 회차 미발신은 MVP 트레이드오프로 허용한다.
    tx.update(sessionRef, {
      reminderSent: true,
      updatedAt: FieldValue.serverTimestamp()
    });

    return session;
  });
}

async function sendSessionReminder(gameSessionId: string, session: GameSession): Promise<void> {
  const confirmedSnap = await db
    .collection(COLLECTIONS.PARTICIPATIONS)
    .where("gameSessionId", "==", gameSessionId)
    .where("status", "==", PARTICIPATION_STATUS.CONFIRMED)
    .get();

  const startsAt = formatStartsAt(session.startsAt);
  const fieldName = session.fieldName ?? "";
  const body =
    fieldName.length > 0
      ? `${session.title} 게임이 ${startsAt}에 시작됩니다. ${fieldName}에서 만나요`
      : `${session.title} 게임이 ${startsAt}에 시작됩니다`;

  const envelopes: NotificationEnvelope[] = confirmedSnap.docs.map((doc) => {
    const participation = doc.data() as Participation;
    return {
      type: "session.upcoming_reminder",
      userId: participation.userId,
      title: "게임 24시간 전 안내",
      body,
      actionUrl: `/sessions/${gameSessionId}`,
      gameSessionId,
      participationId: doc.id,
      data: { startsAt, fieldName }
    };
  });

  await notifier.sendMany(envelopes);
}

export const scheduledReminder = onSchedule(
  { schedule: "every 30 minutes", timeZone: "Asia/Seoul", region: REGION },
  async () => {
    const nowMs = Timestamp.now().toMillis();
    const candidateIds = await collectReminderCandidates(nowMs);

    await Promise.all(
      candidateIds.map(async (gameSessionId) => {
        try {
          const session = await markReminderSent(gameSessionId, nowMs);
          if (!session) return;
          await sendSessionReminder(gameSessionId, session);
        } catch (error) {
          console.error("scheduledReminder failed", {
            gameSessionId,
            error
          });
        }
      })
    );
  }
);
