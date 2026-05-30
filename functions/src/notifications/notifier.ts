// B3-3 알림 seam — FCM 실 발신은 후속(B1-4/A8 이후). 지금은 호출 지점만 확보한다.
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

/** 실 FCM 미구현 단계의 기본 구현. 트랜잭션 커밋 후 호출된다. */
export class NoopNotifier implements Notifier {
  async send(envelope: NotificationEnvelope): Promise<void> {
    // TODO(B1-4/A8): admin.messaging().sendEachForMulticast() + notifications 컬렉션 영속화로 교체
    if (process.env.FUNCTIONS_EMULATOR === "true") {
      console.debug(`[notifier:noop] ${envelope.type} -> ${envelope.userId}`);
    }
    return Promise.resolve();
  }

  async sendMany(envelopes: NotificationEnvelope[]): Promise<void> {
    await Promise.all(envelopes.map((envelope) => this.send(envelope)));
  }
}

// 단일 인스턴스 — 후속에 FcmNotifier로 교체할 단일 지점.
export const notifier: Notifier = new NoopNotifier();
