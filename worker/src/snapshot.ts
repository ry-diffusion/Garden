import { HttpError } from "./http";
import { PluggyClient } from "./pluggy";

/**
 * A trailing-window snapshot of one item, built per request and never stored (DESIGN §13).
 * The app diffs it against its ledger: new → insert, changed → update, missing → tombstone.
 */
export interface Snapshot {
	itemId: string;
	from: string;
	fetchedAt: string;
	item: unknown;
	accounts: unknown[];
	transactions: Record<string, unknown[]>; // by accountId
	bills: Record<string, unknown[]>; // by credit-card accountId
	investments: unknown[];
	loans: unknown[];
	identity: { fullName?: string; document?: string; documentType?: string } | null;
	/** Optional products that Pluggy refused for this item ("loans: pluggy_error 403 /loans"). */
	warnings: string[];
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** `from` defaults to 35 days ago; the first sync asks for up to 12 months. */
export function resolveFrom(raw: string | null, now = new Date()): string {
	const earliest = new Date(now);
	earliest.setUTCMonth(earliest.getUTCMonth() - 12);
	if (raw === null) {
		const fallback = new Date(now.getTime() - 35 * 86_400_000);
		return fallback.toISOString().slice(0, 10);
	}
	if (!DATE.test(raw) || Number.isNaN(Date.parse(raw))) throw new HttpError(400, "from_must_be_yyyy_mm_dd");
	const from = new Date(`${raw}T00:00:00Z`);
	return (from < earliest ? earliest : from).toISOString().slice(0, 10);
}

export async function buildSnapshot(env: Env, itemId: string, from: string): Promise<Snapshot> {
	const pluggy = new PluggyClient(env);
	const item = await pluggy.getItem(itemId);
	if (!item) throw new HttpError(404, "item_not_found");

	// Accounts and their transactions are the point of a snapshot; everything else is best effort, because
	// Meu Pluggy items (and development apps) don't offer every product.
	const warnings: string[] = [];
	const optional = async <T>(name: string, task: () => Promise<T>, fallback: T): Promise<T> => {
		try {
			return await task();
		} catch (error) {
			if (error instanceof HttpError && error.status === 503) throw error; // rate limited: retry later as a whole
			warnings.push(`${name}: ${error instanceof Error ? error.message : String(error)}`);
			return fallback;
		}
	};

	const accounts = await pluggy.listAccounts(itemId);
	const [investments, loans, identity] = await Promise.all([
		optional("investments", () => pluggy.listInvestments(itemId), [] as unknown[]),
		optional("loans", () => pluggy.listLoans(itemId), [] as unknown[]),
		optional("identity", () => pluggy.identity(itemId), null),
	]);

	const transactions: Record<string, unknown[]> = {};
	const bills: Record<string, unknown[]> = {};
	// Accounts sequentially: a handful per item, and it keeps us far from Pluggy's 360 req/min.
	for (const account of accounts) {
		transactions[account.id] = await optional(`transactions ${account.id}`, () => pluggy.listTransactions(account.id, from), []);
		if (account.type === "CREDIT") bills[account.id] = await optional(`bills ${account.id}`, () => pluggy.listBills(account.id), []);
	}
	if (warnings.length) console.warn(JSON.stringify({ event: "snapshot_warnings", itemId, warnings }));

	return { itemId, from, fetchedAt: new Date().toISOString(), item, accounts, transactions, bills, investments, loans, identity, warnings };
}
