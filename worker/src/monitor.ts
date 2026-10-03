import { pingDevices } from "./apns";
import { listItemIds } from "./items";
import { PluggyClient } from "./pluggy";

/**
 * Hourly: has any item refreshed since we last looked? Meu Pluggy refreshes once a day, so this
 * pings the app at most a few times per day and never pulls transactions itself (REVIEW.md C11).
 */
export async function checkItems(env: Env): Promise<{ changed: string[]; pinged: number }> {
	const pluggy = new PluggyClient(env);
	const changed: string[] = [];

	for (const itemId of await listItemIds(env)) {
		const item = await pluggy.getItem(itemId);
		if (!item) continue;
		const fingerprint = `${item.lastUpdatedAt ?? ""}|${item.status}|${item.executionStatus}`;
		const key = `fp:${itemId}`;
		if ((await env.GARDEN.get(key)) === fingerprint) continue;
		await env.GARDEN.put(key, fingerprint);
		changed.push(itemId);
	}

	const pinged = changed.length ? await pingDevices(env, { event: "items_changed", items: changed.join(",") }) : 0;
	console.log(JSON.stringify({ event: "items_checked", changed: changed.length, pinged }));
	return { changed, pinged };
}
