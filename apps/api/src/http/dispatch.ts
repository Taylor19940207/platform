// 已拆出模組的路由表。
//
// server.ts 先問這裡；沒有命中才落回它自己的 if 鏈。
// 這樣可以**一個模組一次**地搬，而不需要先重排全部路由——
// 一次搬完的話，回歸差異就分不清是哪個模組造成的。
import type { AuthenticatedContext } from "./context.ts";
import type { Respond } from "./respond.ts";
import * as periods from "../modules/periods/routes.ts";
import * as adjustments from "../modules/adjustments/routes.ts";
import * as imports from "../modules/imports/routes.ts";
import * as mappings from "../modules/mappings/routes.ts";
import * as calculations from "../modules/calculations/routes.ts";
import * as evidence from "../modules/evidence/routes.ts";
import * as identities from "../modules/identities/routes.ts";

export type RouteHandler = (ctx: AuthenticatedContext, send: Respond) => Promise<void>;

const ROUTES: Record<string, RouteHandler> = {
  "POST /period/transition": periods.transition,
  "POST /b04/accept": imports.accept,
  "GET /b04": mappings.view,
  "POST /b04/map": mappings.createMapping,
  "POST /b04/approve": mappings.approveMapping,
  "GET /b04/preview": mappings.preview,
  "POST /b04/submit": mappings.submitMapping,
  "POST /b06/run": calculations.createRun,
  "GET /b06/run": calculations.runView,
  "POST /b06/replay": calculations.replay,
  "GET /b06": calculations.list,
  "POST /b07/package": evidence.createPackage,
  "GET /b07/package": evidence.packageView,
  "GET /b07": evidence.list,
  "GET /b07/download": evidence.download,
  "GET /b03/identity": identities.identityView,
  "POST /b03/identity/confirm": identities.identityConfirm,
  "POST /b05/create": adjustments.create,
  "GET /b05": adjustments.view,
  "POST /b05/save": adjustments.save,
  "POST /b05/submit": adjustments.submit,
  "POST /b05/review": adjustments.review,
  "POST /b05/return": adjustments.returnDraft,
  "POST /b05/approve": adjustments.approve,
};

/** 命中則執行並回傳 true；未命中回傳 false，由呼叫端繼續原有分派。 */
export async function dispatch(ctx: AuthenticatedContext, send: Respond): Promise<boolean> {
  const handler = ROUTES[`${ctx.method} ${ctx.url.pathname}`];
  if (!handler) return false;
  await handler(ctx, send);
  return true;
}
