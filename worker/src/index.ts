import type { PushRegistration } from "./apns";
import { authenticate, createPairingCode, redeemPairingCode, requireAdmin, revokeDevice } from "./auth";
import { lookupCompany } from "./cnpj";
import { HttpError, errorResponse, json, readJson } from "./http";
import { itemStatuses, requireKnownItem, setItemIds } from "./items";
import { acquireLease } from "./lease";
import { checkItems } from "./monitor";
import { buildSnapshot, resolveFrom } from "./snapshot";

/**
 * Garden API (DESIGN.md §13). A stateless proxy: Pluggy secrets stay here, financial data passes
 * through to the paired app and is never stored.
 *
 *   GET    /v1/health
 *   POST   /v1/pair/code             admin → single-use pairing code (10 min)
 *   POST   /v1/pair                  {code, deviceName} → device token (rate limited)
 *   DELETE /v1/devices/self          revoke this device
 *   POST   /v1/devices/push          {token, environment} register for silent pushes
 *   GET    /v1/items                 whitelisted Meu Pluggy items + status
 *   PUT    /v1/items                 {itemIds} replace the whitelist
 *   GET    /v1/items/:id/snapshot    ?from=YYYY-MM-DD trailing-window snapshot
 *   POST   /v1/lease                 single-writer ingestion lease
 *   GET    /v1/merchants/:cnpj       company registry lookup (cached)
 */
async function route(request: Request, env: Env): Promise<Response> {
	const url = new URL(request.url);
	const path = url.pathname.replace(/\/+$/, "");
	const method = request.method;

	if (method === "GET" && path === "/v1/health") return json({ ok: true });

	if (method === "POST" && path === "/v1/pair/code") {
		await requireAdmin(request, env);
		return json(await createPairingCode(env), { status: 201 });
	}

	if (method === "POST" && path === "/v1/pair") {
		const body = await readJson<{ code?: unknown; deviceName?: unknown }>(request);
		if (typeof body.code !== "string") throw new HttpError(400, "code_required");
		const deviceName = typeof body.deviceName === "string" ? body.deviceName : "Garden";
		return json(await redeemPairingCode(request, env, body.code, deviceName), { status: 201 });
	}

	// Everything below requires a paired device.
	const device = await authenticate(request, env);

	if (method === "DELETE" && path === "/v1/devices/self") {
		await revokeDevice(env, device);
		return new Response(null, { status: 204 });
	}

	if (method === "POST" && path === "/v1/devices/push") {
		const body = await readJson<Partial<PushRegistration>>(request);
		if (typeof body.token !== "string" || !/^[0-9a-f]{64,200}$/i.test(body.token)) throw new HttpError(400, "invalid_push_token");
		const registration: PushRegistration = { token: body.token, environment: body.environment === "sandbox" ? "sandbox" : "production" };
		await env.GARDEN.put(`push:${device.id}`, JSON.stringify(registration));
		return new Response(null, { status: 204 });
	}

	if (method === "GET" && path === "/v1/items") return json({ items: await itemStatuses(env) });

	if (method === "PUT" && path === "/v1/items") {
		const body = await readJson<{ itemIds?: unknown }>(request);
		return json({ items: await setItemIds(env, body.itemIds) });
	}

	const snapshot = /^\/v1\/items\/([0-9a-f-]{36})\/snapshot$/i.exec(path);
	if (method === "GET" && snapshot?.[1]) {
		const itemId = snapshot[1].toLowerCase();
		await requireKnownItem(env, itemId);
		return json(await buildSnapshot(env, itemId, resolveFrom(url.searchParams.get("from"))));
	}

	if (method === "POST" && path === "/v1/lease") {
		const lease = await acquireLease(env, device.id);
		return json(lease, { status: lease.granted ? 200 : 409 });
	}

	const merchant = /^\/v1\/merchants\/([\d./-]{14,18})$/.exec(path);
	if (method === "GET" && merchant?.[1]) return json(await lookupCompany(env, merchant[1]));

	throw new HttpError(404, "not_found");
}

export default {
	async fetch(request, env): Promise<Response> {
		try {
			return await route(request, env);
		} catch (error) {
			return errorResponse(error);
		}
	},

	async scheduled(_controller, env, ctx): Promise<void> {
		ctx.waitUntil(
			checkItems(env).then(
				() => undefined,
				(error: unknown) => console.error(JSON.stringify({ event: "items_check_failed", message: error instanceof Error ? error.message : String(error) })),
			),
		);
	},
} satisfies ExportedHandler<Env>;
