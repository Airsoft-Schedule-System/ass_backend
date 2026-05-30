// Cloud Functions 진입점 (GREEN 범위). Admin 초기화는 config/runtime.ts import 시 수행됨.
export { onUserCreate } from "./triggers/onUserCreate";
export {
  createGameSession,
  requestParticipation,
  approveParticipation,
  rejectParticipation,
  approvePayment,
  rejectPayment
} from "./functions";

// TODO(후속 — 선행 결정/인프라 의존, 본 GREEN 범위 외):
//  updateGameSession, cancelGameSession(tx), cancelParticipation(tx), submitPayment,
//  requestRefund, processRefund, getEntryPassToken, scanEntryPass(tx),
//  onParticipationConfirmed(EntryPass 발급 트리거, A5), scheduledStatusTransition, scheduledReminder(A8)
