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
  markAttendance,
  submitPayment,
  approvePayment,
  rejectPayment,
  requestRefund,
  getEntryPassToken,
  scanEntryPass
} from "./functions";
export { scheduledStatusTransition } from "./functions/scheduled/statusTransition";
export { scheduledReminder } from "./functions/scheduled/reminder";
export { onParticipationConfirmed } from "./triggers/onParticipationConfirmed";

// TODO(후속 — 선행 결정/인프라 의존):
//  processRefund(A3 비활성)
