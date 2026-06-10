// B3-3 확장성 seam 유지 규칙 (검토 문서 B3-3 항목 1:1)
import { PAYMENT_METHOD } from "./status";

// (a) paymentMethod 분기 seam: 현재 PRE_TRANSFER 단일. 결제수단 비교는 이 헬퍼 경유(현장결제 대비).
export function isPreTransfer(method: string): boolean {
  return method === PAYMENT_METHOD.PRE_TRANSFER;
}

// (c) denormalization 동기화 규칙: startsAt 불변 전제(gameStartsAt 등 파생필드 보존).
//     updateGameSession(후속)은 아래 필드 변경을 금지해야 한다.
export const IMMUTABLE_SESSION_FIELDS = [
  "startsAt",
  "createdByUserId",
  "confirmedCount",
  "status"
] as const;

// (b) EntryPass 발급 트리거 단일화: EntryPass 생성은 onParticipationConfirmed 한 곳에서만(범위 외).
//     approvePayment 등 다른 함수에서 직접 생성하지 않는다.
// (d) 알림 envelope 표준: notifications/notifier.ts 의 NotificationEnvelope 단일 형태 사용.
