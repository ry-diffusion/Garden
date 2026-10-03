import { HttpError } from "./http";
import { PluggyClient, type PluggyItem } from "./pluggy";

/**
 * The item whitelist. Meu Pluggy can't list items (`GET /v2/items` is unavailable), so the owner
 * registers the itemIds; every Pluggy call is checked against this list.
 */
const ITEMS_KEY = "items";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function listItemIds(env: Env): Promise<string[]> {
	return (await env.GARDEN.get<string[]>(ITEMS_KEY, "json")) ?? [];
}

export async function requireKnownItem(env: Env, itemId: string): Promise<void> {
	if (!(await listItemIds(env)).includes(itemId)) throw new HttpError(404, "unknown_item");
}

export interface ItemStatus {
	id: string;
	institution: string | null;
	imageUrl: string | null;
	status: string;
	executionStatus: string;
	lastUpdatedAt: string | null;
	nextAutoSyncAt: string | null;
	consentExpiresAt: string | null;
	error: string | null;
}

function summarize(item: PluggyItem): ItemStatus {
	return {
		id: item.id,
		institution: item.connector?.name ?? null,
		imageUrl: item.connector?.imageUrl ?? null,
		status: item.status,
		executionStatus: item.executionStatus,
		lastUpdatedAt: item.lastUpdatedAt ?? null,
		nextAutoSyncAt: item.nextAutoSyncAt ?? null,
		consentExpiresAt: item.consentExpiresAt ?? null,
		error: item.error?.message ?? item.error?.code ?? null,
	};
}

export async function itemStatuses(env: Env): Promise<ItemStatus[]> {
	const pluggy = new PluggyClient(env);
	const ids = await listItemIds(env);
	const items = await Promise.all(ids.map((id) => pluggy.getItem(id)));
	return items.flatMap((item, index) =>
		item
			? [summarize(item)]
			: [{ id: ids[index] ?? "", institution: null, imageUrl: null, status: "NOT_FOUND", executionStatus: "NOT_FOUND", lastUpdatedAt: null, nextAutoSyncAt: null, consentExpiresAt: null, error: "item_not_found" }],
	);
}

/** Replaces the whitelist; each id must be a real item for these Pluggy credentials. Meu Pluggy allows ≤ 5. */
export async function setItemIds(env: Env, itemIds: unknown): Promise<ItemStatus[]> {
	if (!Array.isArray(itemIds) || itemIds.length > 10 || !itemIds.every((id) => typeof id === "string" && UUID.test(id))) {
		throw new HttpError(400, "item_ids_must_be_uuids");
	}
	const unique = [...new Set(itemIds.map((id: string) => id.toLowerCase()))];
	const pluggy = new PluggyClient(env);
	const items = await Promise.all(unique.map((id) => pluggy.getItem(id)));
	const missing = unique.filter((_, index) => !items[index]);
	if (missing.length) throw new HttpError(422, `unknown_items:${missing.join(",")}`);
	await env.GARDEN.put(ITEMS_KEY, JSON.stringify(unique));
	return items.flatMap((item) => (item ? [summarize(item)] : []));
}
