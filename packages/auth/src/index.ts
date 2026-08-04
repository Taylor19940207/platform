// 身分與 EngagementContext（骨架）。
// 伺服器端必須重新驗證物件與 Engagement 一致（§24.1A）——不得信任前端選單。
export interface EngagementContext {
  tenantId: string; userId: string;
  engagementId: string; legalEntityId: string; periodRevisionId: string;
  editSessionId: string;   // 同一人不同分頁＝不同編輯來源（§27.4A）
}
