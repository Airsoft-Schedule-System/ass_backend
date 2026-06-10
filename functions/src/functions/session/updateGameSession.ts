// api-spec §2.3 — 게임 세션 수정. startsAt 등 불변 필드는 validation에서 차단한다.
import { onCall } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../../config/runtime";
import { COLLECTIONS } from "../../lib/collections";
import { errInvalidArgument, errNotFound } from "../../lib/errors";
import { assertSessionStatusAllows } from "../../lib/guards";
import { assertSessionOwner, requireAuth } from "../../lib/permissions";
import { PARTICIPATION_STATUS } from "../../lib/status";
import { toTimestamp } from "../../lib/time";
import { asNonEmptyString, validateSessionUpdates } from "../../lib/validation";
import { notifier, type NotificationEnvelope } from "../../notifications/notifier";
import type { GameSession, Participation } from "../../types/entities";
import type { UpdateGameSessionOutput } from "../../types/functions";

function readUpdates(value: unknown): Record<string, unknown> {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    throw errInvalidArgument("updates는 객체여야 합니다");
  }
  return { ...(value as Record<string, unknown>) };
}

export const updateGameSession = onCall(
  { region: REGION },
  async (request): Promise<UpdateGameSessionOutput> => {
    const uid = requireAuth(request.auth);
    const data = (request.data ?? {}) as Record<string, unknown>;
    const gameSessionId = asNonEmptyString(data.gameSessionId, "gameSessionId");
    const updates = readUpdates(data.updates);

    if ("cancelDeadline" in updates) {
      updates.cancelDeadline = toTimestamp(updates.cancelDeadline, "updates.cancelDeadline");
    }
    if ("endsAt" in updates) {
      updates.endsAt = toTimestamp(updates.endsAt, "updates.endsAt");
    }

    const result = await db.runTransaction(async (tx) => {
      const sessionRef = db.collection(COLLECTIONS.GAME_SESSIONS).doc(gameSessionId);
      const sessionSnap = await tx.get(sessionRef);
      if (!sessionSnap.exists) throw errNotFound("게임 세션을 찾을 수 없습니다");
      const session = sessionSnap.data() as GameSession;

      assertSessionOwner(session, uid);
      assertSessionStatusAllows("updateGameSession", session);

      const cancelDeadlineMs =
        "cancelDeadline" in updates && updates.cancelDeadline
          ? (updates.cancelDeadline as { toMillis(): number }).toMillis()
          : undefined;
      const updatedFields = validateSessionUpdates(
        updates,
        {
          capacity: session.capacity,
          confirmedCount: session.confirmedCount,
          presetId: session.presetId,
          startsAtMs: session.startsAt.toMillis()
        },
        cancelDeadlineMs
      );

      const updatePayload: Record<string, unknown> = {
        updatedAt: FieldValue.serverTimestamp()
      };
      for (const field of updatedFields) {
        updatePayload[field] = updates[field];
      }

      tx.update(sessionRef, updatePayload);

      return {
        updatedFields,
        shouldNotify:
          updatedFields.includes("capacity") || updatedFields.includes("customRules"),
        title:
          typeof updates.title === "string" && updates.title.trim().length > 0
            ? updates.title
            : session.title
      };
    });

    if (result.shouldNotify) {
      const confirmedSnap = await db
        .collection(COLLECTIONS.PARTICIPATIONS)
        .where("gameSessionId", "==", gameSessionId)
        .where("status", "==", PARTICIPATION_STATUS.CONFIRMED)
        .get();
      const envelopes: NotificationEnvelope[] = confirmedSnap.docs.map((doc) => {
        const participation = doc.data() as Participation;
        return {
          type: "session.changed",
          userId: participation.userId,
          title: "게임 세션 정보가 변경되었습니다",
          body: `${result.title} 세션 정보가 변경되었습니다`,
          actionUrl: `/sessions/${gameSessionId}`,
          gameSessionId,
          participationId: doc.id,
          data: { type: "updated", updatedFields: result.updatedFields.join(",") }
        };
      });
      await notifier.sendMany(envelopes);
    }

    return { success: true, updatedFields: result.updatedFields };
  }
);
