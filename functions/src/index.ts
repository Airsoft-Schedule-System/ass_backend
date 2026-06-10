// Cloud Functions 진입점 (GREEN 범위). Admin 초기화는 config/runtime.ts import 시 수행됨.
export { onUserCreate } from "./triggers/onUserCreate";
export {
  createGameSession,
  updateGameSession,
  cancelGameSession,
  requestParticipation,
  joinAsOperator,
  approveParticipation,
  rejectParticipation,
  cancelParticipation,
  submitPayment,
  approvePayment,
  rejectPayment,
  requestRefund
} from "./functions";
export { scheduledStatusTransition } from "./functions/scheduled/statusTransition";

// TODO(후속 — 선행 결정/인프라 의존, Wave 1 범위 외):
//  processRefund(A3 비활성), getEntryPassToken, scanEntryPass(tx),
//  markAttendance, onParticipationConfirmed(EntryPass 발급 트리거, A5), scheduledReminder(A8)
