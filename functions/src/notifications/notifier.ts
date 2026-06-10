import { FieldValue } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { db } from "../config/runtime";
import { COLLECTIONS, SUBCOLLECTIONS } from "../lib/collections";
import type { UserFcmToken } from "../types/entities";

export interface NotificationEnvelope {
  type: string; // api-spec §4 이벤트 타입
  userId: string; // 수신자
  title: string;
  body: string;
  actionUrl: string;
  data?: Record<string, string>; // FCM data payload는 string-only
  gameSessionId?: string;
  participationId?: string;
}

export interface Notifier {
  send(envelope: NotificationEnvelope): Promise<void>;
  sendMany(envelopes: NotificationEnvelope[]): Promise<void>;
}

const INVALID_FCM_TOKEN_CODES = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-argument",
  "messaging/invalid-registration-token",
  "invalid-registration-token"
]);

export function shouldDeleteFcmToken(errorCode: string): boolean {
  return INVALID_FCM_TOKEN_CODES.has(errorCode);
}

/** 테스트/로컬 대체용 구현. 기본 싱글턴은 FcmNotifier를 사용한다. */
export class NoopNotifier implements Notifier {
  async send(envelope: NotificationEnvelope): Promise<void> {
    if (process.env.FUNCTIONS_EMULATOR === "true") {
      console.debug(`[notifier:noop] ${envelope.type} -> ${envelope.userId}`);
    }
    return Promise.resolve();
  }

  async sendMany(envelopes: NotificationEnvelope[]): Promise<void> {
    await Promise.all(envelopes.map((envelope) => this.send(envelope)));
  }
}

export class FcmNotifier implements Notifier {
  async send(envelope: NotificationEnvelope): Promise<void> {
    try {
      await this.persistNotification(envelope);
    } catch (error) {
      console.error("notification persistence failed", {
        userId: envelope.userId,
        type: envelope.type,
        error
      });
      return;
    }

    try {
      const tokenSnap = await db
        .collection(COLLECTIONS.USERS)
        .doc(envelope.userId)
        .collection(SUBCOLLECTIONS.FCM_TOKENS)
        .get();

      const tokenDocs = tokenSnap.docs
        .map((doc) => ({
          ref: doc.ref,
          token: (doc.data() as UserFcmToken).token
        }))
        .filter((doc): doc is { ref: FirebaseFirestore.DocumentReference; token: string } =>
          typeof doc.token === "string" && doc.token.length > 0
        );

      if (tokenDocs.length === 0) return;

      const response = await getMessaging().sendEachForMulticast({
        tokens: tokenDocs.map((doc) => doc.token),
        notification: {
          title: envelope.title,
          body: envelope.body
        },
        data: {
          type: envelope.type,
          actionUrl: envelope.actionUrl,
          ...(envelope.data ?? {})
        }
      });

      await Promise.all(
        response.responses.map(async (sendResponse, index) => {
          const errorCode = sendResponse.error?.code;
          if (!errorCode || !shouldDeleteFcmToken(errorCode)) return;

          try {
            await tokenDocs[index].ref.delete();
          } catch (error) {
            console.error("fcm token deletion failed", {
              userId: envelope.userId,
              errorCode,
              error
            });
          }
        })
      );
    } catch (error) {
      console.error("fcm notification send failed", {
        userId: envelope.userId,
        type: envelope.type,
        error
      });
    }
  }

  async sendMany(envelopes: NotificationEnvelope[]): Promise<void> {
    await Promise.allSettled(envelopes.map((envelope) => this.send(envelope)));
  }

  private async persistNotification(envelope: NotificationEnvelope): Promise<void> {
    await db.collection(COLLECTIONS.NOTIFICATIONS).add({
      userId: envelope.userId,
      type: envelope.type,
      title: envelope.title,
      body: envelope.body,
      actionUrl: envelope.actionUrl,
      data: envelope.data ?? null,
      gameSessionId: envelope.gameSessionId ?? null,
      participationId: envelope.participationId ?? null,
      isRead: false,
      createdAt: FieldValue.serverTimestamp()
    });
  }
}

export const notifier: Notifier = new FcmNotifier();
