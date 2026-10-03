import { HttpError } from "./http";

/**
 * Minimal Pluggy client. Only ever talks to `PLUGGY_API_BASE` (configured by the owner, never taken
 * from a request), so a caller can't steer the API key to another host (REVIEW.md C3).
 */

// The 2 h apiKey is a credential cache shared across requests in this isolate — not request state.
let cachedKey: { clientId: string; apiKey: string; expiresAt: number } | undefined;
const API_KEY_LIFETIME_MS = 110 * 60 * 1000; // Pluggy keys last 2 h; refresh 10 min early.
const MAX_PAGES = 200;

export interface PluggyItem {
	id: string;
	status: string;
	executionStatus: string;
	lastUpdatedAt: string | null;
	nextAutoSyncAt?: string | null;
	consentExpiresAt?: string | null;
	error?: { code?: string; message?: string } | null;
	connector?: { id: number; name: string; imageUrl?: string; primaryColor?: string };
}

export interface PluggyAccount {
	id: string;
	type: "BANK" | "CREDIT" | string;
	subtype: string;
	number?: string;
	name?: string;
	marketingName?: string | null;
	balance?: number;
	currencyCode?: string;
	creditData?: Record<string, unknown> | null;
	bankData?: Record<string, unknown> | null;
}

type Paged<T> = { results: T[]; next?: string | null; totalPages?: number; page?: number };

export class PluggyClient {
	private readonly base: string;

	constructor(private readonly env: Env) {
		this.base = (env.PLUGGY_API_BASE || "https://api.pluggy.ai").replace(/\/$/, "");
	}

	private async apiKey(force = false): Promise<string> {
		const now = Date.now();
		if (!force && cachedKey && cachedKey.clientId === this.env.PLUGGY_CLIENT_ID && cachedKey.expiresAt > now) {
			return cachedKey.apiKey;
		}
		const response = await fetch(`${this.base}/auth`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ clientId: this.env.PLUGGY_CLIENT_ID, clientSecret: this.env.PLUGGY_CLIENT_SECRET }),
		});
		if (!response.ok) throw new HttpError(502, "pluggy_auth_failed");
		const { apiKey } = await response.json<{ apiKey: string }>();
		cachedKey = { clientId: this.env.PLUGGY_CLIENT_ID, apiKey, expiresAt: now + API_KEY_LIFETIME_MS };
		return apiKey;
	}

	/** GET with one re-auth on 401 and honest pass-through of rate limits. Returns null on 404. */
	async get<T>(path: string, params: Record<string, string | undefined> = {}): Promise<T | null> {
		const url = new URL(this.base + path);
		for (const [key, value] of Object.entries(params)) if (value !== undefined) url.searchParams.set(key, value);

		for (const attempt of [0, 1]) {
			const response = await fetch(url, { headers: { "x-api-key": await this.apiKey(attempt === 1) } });
			if (response.status === 401 && attempt === 0) continue;
			if (response.status === 404) return null;
			if (response.status === 429) {
				throw new HttpError(503, "pluggy_rate_limited", { "retry-after": response.headers.get("retry-after") ?? "60" });
			}
			if (!response.ok) {
				const body = (await response.text()).slice(0, 300);
				console.error(JSON.stringify({ event: "pluggy_error", path, status: response.status, requestId: response.headers.get("x-request-id"), body }));
				// Path + status only: enough to diagnose, nothing sensitive.
				throw new HttpError(502, `pluggy_error ${response.status} ${path}`);
			}
			return response.json<T>();
		}
		throw new HttpError(502, "pluggy_auth_failed");
	}

	getItem(itemId: string): Promise<PluggyItem | null> {
		return this.get<PluggyItem>(`/items/${encodeURIComponent(itemId)}`);
	}

	async listAccounts(itemId: string): Promise<PluggyAccount[]> {
		return (await this.get<Paged<PluggyAccount>>("/accounts", { itemId }))?.results ?? [];
	}

	/** /v2/transactions with cursor pagination. `next` is followed only as a cursor on our own base URL. */
	async listTransactions(accountId: string, dateFrom: string): Promise<unknown[]> {
		const all: unknown[] = [];
		let after: string | undefined;
		for (let page = 0; page < MAX_PAGES; page++) {
			const result = await this.get<Paged<unknown>>("/v2/transactions", { accountId, dateFrom, after });
			all.push(...(result?.results ?? []));
			after = cursor(result?.next);
			if (!after) break;
		}
		return all;
	}

	async listInvestments(itemId: string): Promise<unknown[]> {
		return (await this.get<Paged<unknown>>("/investments", { itemId }))?.results ?? [];
	}

	async listBills(accountId: string): Promise<unknown[]> {
		return (await this.get<Paged<unknown>>("/bills", { accountId }))?.results ?? [];
	}

	async listLoans(itemId: string): Promise<unknown[]> {
		return (await this.get<Paged<unknown>>("/loans", { itemId }))?.results ?? [];
	}

	/** Only what the app needs to recognize "me" in Pix counterparts. */
	async identity(itemId: string): Promise<{ fullName?: string; document?: string; documentType?: string } | null> {
		const identity = await this.get<{ fullName?: string; document?: string; documentType?: string }>("/identity", { itemId });
		return identity ? { fullName: identity.fullName, document: identity.document, documentType: identity.documentType } : null;
	}
}

/**
 * Accepts a bare cursor, an absolute "next" URL or a relative one ("/v2/transactions?…&after=…"),
 * keeping only its cursor value — never its host.
 */
export function cursor(next: string | null | undefined): string | undefined {
	if (!next) return undefined;
	if (/^https?:\/\//i.test(next) || next.startsWith("/") || next.includes("?") || next.includes("after=")) {
		try {
			const url = new URL(next, "https://pluggy.invalid");
			return url.searchParams.get("after") ?? url.searchParams.get("cursor") ?? undefined;
		} catch {
			return undefined;
		}
	}
	return next;
}

/** For tests: forget the cached apiKey. */
export function resetPluggyKeyCache(): void {
	cachedKey = undefined;
}
