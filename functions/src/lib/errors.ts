// api-spec-v2 §1.4 에러 모델 — HttpsError 코드별 팩토리
import { HttpsError } from "firebase-functions/v2/https";

export const errUnauthenticated = (message = "로그인이 필요합니다"): HttpsError =>
  new HttpsError("unauthenticated", message);

export const errPermissionDenied = (message = "권한이 없습니다"): HttpsError =>
  new HttpsError("permission-denied", message);

export const errNotFound = (message = "대상을 찾을 수 없습니다"): HttpsError =>
  new HttpsError("not-found", message);

export const errInvalidArgument = (message: string): HttpsError =>
  new HttpsError("invalid-argument", message);

export const errFailedPrecondition = (message: string): HttpsError =>
  new HttpsError("failed-precondition", message);

export const errAlreadyExists = (message: string): HttpsError =>
  new HttpsError("already-exists", message);
