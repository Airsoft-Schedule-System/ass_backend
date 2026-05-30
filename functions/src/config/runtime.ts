// 런타임 공통 설정 — Admin 초기화, 리전, 시크릿 정의, Firestore 핸들
import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";

if (getApps().length === 0) {
  initializeApp();
}

// 한국 사용자 기준 기본 리전 (미확정 기본값, 추후 조정 가능)
export const REGION = "asia-northeast3";

// 본 GREEN 범위 함수는 미사용. 후속(QR 출석/환불) 대비 정의만 둔다.
export const QR_HMAC_SECRET = defineSecret("QR_HMAC_SECRET");
export const REFUND_ACCOUNT_KEY = defineSecret("REFUND_ACCOUNT_KEY");

export const db = getFirestore();
