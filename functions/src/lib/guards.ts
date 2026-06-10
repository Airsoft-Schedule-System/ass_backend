// B1-1 정원 가드 + B1-2 운영 mutation 세션상태 화이트리스트
import { errFailedPrecondition } from "./errors";
import { SESSION_STATUS } from "./status";
import type { GameSessionStatus } from "../types/status";

export interface CapacityView {
  confirmedCount: number;
  capacity: number;
}

/** B1-1: approvePayment 트랜잭션 내부 선검증. 정원이 가득 차 있으면 거부. */
export function assertCapacityAvailable(session: CapacityView): void {
  if (session.confirmedCount >= session.capacity) {
    throw errFailedPrecondition("정원이 가득 찼습니다");
  }
}

/** confirmedCount += 1 했을 때 정원에 도달하는가 → true면 호출부에서 closed 전이. */
export function reachesCapacityAfterIncrement(session: CapacityView): boolean {
  return session.confirmedCount + 1 >= session.capacity;
}

// B1-2: 운영 mutation별 허용 세션 상태 화이트리스트.
// inProgress/completed/cancelled 이후에는 승인·확정·반려를 차단한다.
export type GuardedOperation =
  | "requestParticipation"
  | "joinAsOperator"
  | "approveParticipation"
  | "rejectParticipation"
  | "submitPayment"
  | "approvePayment"
  | "rejectPayment"
  | "updateGameSession"
  | "cancelGameSession"
  | "scanEntryPass"
  | "markAttendance";

export const OPERATION_SESSION_WHITELIST: Record<
  GuardedOperation,
  readonly GameSessionStatus[]
> = {
  requestParticipation: [SESSION_STATUS.RECRUITING],
  joinAsOperator: [SESSION_STATUS.RECRUITING],
  approveParticipation: [SESSION_STATUS.RECRUITING, SESSION_STATUS.CLOSED],
  rejectParticipation: [SESSION_STATUS.RECRUITING, SESSION_STATUS.CLOSED],
  submitPayment: [SESSION_STATUS.RECRUITING, SESSION_STATUS.CLOSED],
  approvePayment: [SESSION_STATUS.RECRUITING, SESSION_STATUS.CLOSED],
  rejectPayment: [SESSION_STATUS.RECRUITING, SESSION_STATUS.CLOSED],
  updateGameSession: [
    SESSION_STATUS.RECRUITING,
    SESSION_STATUS.CLOSED,
    SESSION_STATUS.IN_PROGRESS
  ],
  cancelGameSession: [
    SESSION_STATUS.RECRUITING,
    SESSION_STATUS.CLOSED,
    SESSION_STATUS.IN_PROGRESS
  ],
  scanEntryPass: [
    SESSION_STATUS.RECRUITING,
    SESSION_STATUS.CLOSED,
    SESSION_STATUS.IN_PROGRESS
  ],
  markAttendance: [
    SESSION_STATUS.RECRUITING,
    SESSION_STATUS.CLOSED,
    SESSION_STATUS.IN_PROGRESS
  ]
};

export function assertSessionStatusAllows(
  operation: GuardedOperation,
  session: { status: GameSessionStatus }
): void {
  if (!OPERATION_SESSION_WHITELIST[operation].includes(session.status)) {
    throw errFailedPrecondition(
      `현재 세션 상태(${session.status})에서는 이 작업을 할 수 없습니다`
    );
  }
}
