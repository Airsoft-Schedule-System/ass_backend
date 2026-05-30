// api-spec §2.1 — 신규 가입 시 users/{uid} 생성.
// role 필드 없음(세션 단위 권한 모델). displayName은 빌 수 있고, 이후 B1-6 서버검증이 가드한다.
import * as functionsV1 from "firebase-functions/v1";
import { FieldValue } from "firebase-admin/firestore";
import { REGION, db } from "../config/runtime";
import { COLLECTIONS } from "../lib/collections";

export const onUserCreate = functionsV1
  .region(REGION)
  .auth.user()
  .onCreate(async (user) => {
    await db
      .collection(COLLECTIONS.USERS)
      .doc(user.uid)
      .set(
        {
          email: user.email ?? null,
          displayName: user.displayName ?? "",
          phoneNumber: user.phoneNumber ?? null,
          teamId: null,
          createdAt: FieldValue.serverTimestamp(),
          lastActiveAt: FieldValue.serverTimestamp()
        },
        { merge: true }
      );
  });
