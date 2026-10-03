import { createExecutionContext, createScheduledController, env, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { cursor, resetPluggyKeyCache } from "../src/pluggy";
import { resolveFrom } from "../src/snapshot";

const ITEM = "6f1c2a4e-3b7d-4e8a-9c21-5d0b7e4f9a13";
const OTHER_ITEM = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";

type Handler = (url: URL, init?: RequestInit) => Response | Promise<Response>;
let pluggyRoutes: Record<string, Handler> = {};
let outbound: URL[] = [];

function mockOutbound() {
	vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
		const url = new URL(input instanceof Request ? input.url : input.toString());
		outbound.push(url);
		if (url.host === "pluggy.test" && url.pathname === "/auth") return Response.json({ apiKey: "key-1" });
		const handler = pluggyRoutes[`${url.host}${url.pathname}`];
		return handler ? handler(url, init) : new Response("not found", { status: 404 });
	});
}

async function call(method: string, path: string, options: { token?: string; body?: unknown; ip?: string } = {}) {
	const headers = new Headers();
	if (options.token) headers.set("authorization", `Bearer ${options.token}`);
	if (options.body !== undefined) headers.set("content-type", "application/json");
	headers.set("cf-connecting-ip", options.ip ?? "203.0.113.7");
	const request = new Request(`https://garden.test${path}`, {
		method,
		headers,
		body: options.body === undefined ? undefined : JSON.stringify(options.body),
	});
	return worker.fetch(request as Parameters<typeof worker.fetch>[0], env);
}

async function pairDevice(name = "iPhone", ip?: string): Promise<string> {
	const codeResponse = await call("POST", "/v1/pair/code", { token: "test-admin-token" });
	const { code } = await codeResponse.json<{ code: string }>();
	const pair = await call("POST", "/v1/pair", { body: { code, deviceName: name }, ip });
	expect(pair.status).toBe(201);
	return (await pair.json<{ token: string }>()).token;
}

function item(id: string, lastUpdatedAt = "2026-10-02T06:00:00.000Z") {
	return { id, status: "UPDATED", executionStatus: "SUCCESS", lastUpdatedAt, connector: { id: 200, name: "MeuPluggy" } };
}

beforeEach(async () => {
	// Storage is shared across tests in this pool version; start every test from an empty KV.
	const keys = await env.GARDEN.list();
	await Promise.all(keys.keys.map((key) => env.GARDEN.delete(key.name)));
	pluggyRoutes = {
		[`pluggy.test/items/${ITEM}`]: () => Response.json(item(ITEM)),
	};
	outbound = [];
	resetPluggyKeyCache();
	mockOutbound();
});

afterEach(() => {
	vi.restoreAllMocks();
});

describe("health & auth", () => {
	it("answers health without auth", async () => {
		expect((await call("GET", "/v1/health")).status).toBe(200);
	});

	it("rejects calls without a device token", async () => {
		expect((await call("GET", "/v1/items")).status).toBe(401);
		expect((await call("GET", "/v1/items", { token: "made-up" })).status).toBe(401);
	});

	it("only the admin can mint pairing codes", async () => {
		expect((await call("POST", "/v1/pair/code")).status).toBe(401);
		expect((await call("POST", "/v1/pair/code", { token: "wrong" })).status).toBe(401);
		expect((await call("POST", "/v1/pair/code", { token: "test-admin-token" })).status).toBe(201);
	});
});

describe("pairing", () => {
	it("swaps a code for a working token, once", async () => {
		const codeResponse = await call("POST", "/v1/pair/code", { token: "test-admin-token" });
		const { code } = await codeResponse.json<{ code: string }>();

		const first = await call("POST", "/v1/pair", { body: { code: code.toLowerCase(), deviceName: "iPhone" } });
		expect(first.status).toBe(201);
		const { token } = await first.json<{ token: string }>();
		expect((await call("GET", "/v1/items", { token })).status).toBe(200);

		const reuse = await call("POST", "/v1/pair", { body: { code, deviceName: "Intruder" } });
		expect(reuse.status).toBe(401);
	});

	it("stores only the token hash", async () => {
		const token = await pairDevice();
		const keys = await env.GARDEN.list({ prefix: "device:" });
		expect(keys.keys.length).toBe(1);
		expect(keys.keys[0]?.name).not.toContain(token);
	});

	it("rate-limits guessing per IP", async () => {
		for (let attempt = 0; attempt < 5; attempt++) {
			expect((await call("POST", "/v1/pair", { body: { code: "WRONG123" }, ip: "198.51.100.1" })).status).toBe(401);
		}
		expect((await call("POST", "/v1/pair", { body: { code: "WRONG123" }, ip: "198.51.100.1" })).status).toBe(429);
	});

	it("revoked devices lose access", async () => {
		const token = await pairDevice();
		expect((await call("DELETE", "/v1/devices/self", { token })).status).toBe(204);
		expect((await call("GET", "/v1/items", { token })).status).toBe(401);
	});
});

describe("items whitelist", () => {
	it("accepts only real Pluggy items", async () => {
		const token = await pairDevice();
		expect((await call("PUT", "/v1/items", { token, body: { itemIds: ["not-a-uuid"] } })).status).toBe(400);
		expect((await call("PUT", "/v1/items", { token, body: { itemIds: [OTHER_ITEM] } })).status).toBe(422);

		const saved = await call("PUT", "/v1/items", { token, body: { itemIds: [ITEM.toUpperCase()] } });
		expect(saved.status).toBe(200);
		const list = await (await call("GET", "/v1/items", { token })).json<{ items: { id: string; status: string }[] }>();
		expect(list.items).toEqual([expect.objectContaining({ id: ITEM, status: "UPDATED" })]);
	});

	it("refuses snapshots of items outside the whitelist", async () => {
		const token = await pairDevice();
		expect((await call("GET", `/v1/items/${ITEM}/snapshot`, { token })).status).toBe(404);
	});
});

describe("snapshot", () => {
	beforeEach(() => {
		pluggyRoutes["pluggy.test/accounts"] = () =>
			Response.json({ results: [{ id: "acc-bank", type: "BANK", subtype: "CHECKING_ACCOUNT" }, { id: "acc-card", type: "CREDIT", subtype: "CREDIT_CARD" }] });
		pluggyRoutes["pluggy.test/v2/transactions"] = (url) => {
			const account = url.searchParams.get("accountId");
			const after = url.searchParams.get("after");
			if (account === "acc-bank" && !after) {
				// A hostile-looking absolute "next": only its cursor may be used, never its host.
				return Response.json({ results: [{ id: "t1" }], next: "https://evil.example/v2/transactions?after=cursor-2" });
			}
			if (account === "acc-bank" && after === "cursor-2") return Response.json({ results: [{ id: "t2" }], next: null });
			return Response.json({ results: [{ id: "c1" }], next: null });
		};
		pluggyRoutes["pluggy.test/bills"] = () => Response.json({ results: [{ id: "bill-1" }] });
		pluggyRoutes["pluggy.test/investments"] = () => Response.json({ results: [{ id: "inv-1" }] });
		pluggyRoutes["pluggy.test/loans"] = () => Response.json({ results: [] });
		pluggyRoutes["pluggy.test/identity"] = () =>
			Response.json({ fullName: "Fulano de Tal", document: "123.456.789-00", documentType: "CPF", addresses: [{ city: "São Paulo" }], phoneNumbers: [] });
	});

	it("follows cursors on Pluggy only and assembles every product", async () => {
		const token = await pairDevice();
		await call("PUT", "/v1/items", { token, body: { itemIds: [ITEM] } });

		const response = await call("GET", `/v1/items/${ITEM}/snapshot?from=2026-09-01`, { token });
		expect(response.status).toBe(200);
		const snapshot = await response.json<Record<string, unknown> & { transactions: Record<string, unknown[]>; identity: Record<string, unknown> }>();

		expect(snapshot.transactions["acc-bank"]).toEqual([{ id: "t1" }, { id: "t2" }]);
		expect(snapshot.transactions["acc-card"]).toEqual([{ id: "c1" }]);
		expect(snapshot.bills).toEqual({ "acc-card": [{ id: "bill-1" }] });
		expect(snapshot.investments).toEqual([{ id: "inv-1" }]);
		// Identity is trimmed to what "is this Pix to myself?" needs.
		expect(snapshot.identity).toEqual({ fullName: "Fulano de Tal", document: "123.456.789-00", documentType: "CPF" });
		expect(outbound.every((url) => url.host === "pluggy.test")).toBe(true);
	});

	it("reads cursors from bare, absolute and relative next values", () => {
		expect(cursor("abc123")).toBe("abc123");
		expect(cursor("https://api.pluggy.ai/v2/transactions?accountId=a&after=c2")).toBe("c2");
		expect(cursor("/v2/transactions?accountId=a&after=c3")).toBe("c3");
		expect(cursor("v2/transactions?after=c4&accountId=a")).toBe("c4");
		expect(cursor(null)).toBeUndefined();
	});

	it("re-authenticates once when the apiKey expires", async () => {
		const token = await pairDevice();
		await call("PUT", "/v1/items", { token, body: { itemIds: [ITEM] } });
		let rejected = false;
		pluggyRoutes["pluggy.test/loans"] = () => {
			if (!rejected) {
				rejected = true;
				return new Response("expired", { status: 401 });
			}
			return Response.json({ results: [] });
		};
		expect((await call("GET", `/v1/items/${ITEM}/snapshot`, { token })).status).toBe(200);
		expect(outbound.filter((url) => url.pathname === "/auth").length).toBe(2);
	});

	it("keeps the snapshot when an optional product is refused", async () => {
		const token = await pairDevice();
		await call("PUT", "/v1/items", { token, body: { itemIds: [ITEM] } });
		pluggyRoutes["pluggy.test/identity"] = () => new Response("not allowed", { status: 403 });
		pluggyRoutes["pluggy.test/loans"] = () => new Response("bad request", { status: 400 });
		const response = await call("GET", `/v1/items/${ITEM}/snapshot`, { token });
		expect(response.status).toBe(200);
		const snapshot = await response.json<{ identity: unknown; transactions: Record<string, unknown[]>; warnings: string[] }>();
		expect(snapshot.identity).toBeNull();
		expect(snapshot.transactions["acc-bank"]?.length).toBe(2);
		expect(snapshot.warnings).toEqual(expect.arrayContaining(["identity: pluggy_error 403 /identity", "loans: pluggy_error 400 /loans"]));
	});

	it("names the failing call when accounts can't be read", async () => {
		const token = await pairDevice();
		await call("PUT", "/v1/items", { token, body: { itemIds: [ITEM] } });
		pluggyRoutes["pluggy.test/accounts"] = () => new Response("forbidden", { status: 403 });
		const response = await call("GET", `/v1/items/${ITEM}/snapshot`, { token });
		expect(response.status).toBe(502);
		expect(await response.json()).toEqual({ error: "pluggy_error 403 /accounts" });
	});

	it("passes Pluggy rate limits through as 503 + retry-after", async () => {
		const token = await pairDevice();
		await call("PUT", "/v1/items", { token, body: { itemIds: [ITEM] } });
		pluggyRoutes["pluggy.test/accounts"] = () => new Response("slow down", { status: 429, headers: { "retry-after": "42" } });
		const response = await call("GET", `/v1/items/${ITEM}/snapshot`, { token });
		expect(response.status).toBe(503);
		expect(response.headers.get("retry-after")).toBe("42");
	});

	it("clamps the window to 12 months and defaults to 35 days", () => {
		const now = new Date("2026-10-03T12:00:00Z");
		expect(resolveFrom(null, now)).toBe("2026-08-29");
		expect(resolveFrom("2020-01-01", now)).toBe("2025-10-03");
		expect(() => resolveFrom("ontem", now)).toThrow();
	});
});

describe("lease", () => {
	it("grants one writer at a time and lets the holder renew", async () => {
		const phone = await pairDevice("iPhone", "192.0.2.1");
		const mac = await pairDevice("Mac", "192.0.2.2");
		expect((await call("POST", "/v1/lease", { token: phone })).status).toBe(200);
		expect((await call("POST", "/v1/lease", { token: mac })).status).toBe(409);
		expect((await call("POST", "/v1/lease", { token: phone })).status).toBe(200);
	});
});

describe("merchants", () => {
	it("returns company fields only and caches them", async () => {
		pluggyRoutes["cnpj.test/47960950000121"] = () =>
			Response.json({
				razao_social: "MAGAZINE LUIZA S/A",
				nome_fantasia: "MAGAZINE LUIZA",
				cnae_fiscal: 4713004,
				municipio: "FRANCA",
				uf: "SP",
				qsa: [{ nome_socio: "PESSOA FISICA" }],
				email: "someone@example.com",
			});
		const token = await pairDevice();
		const first = await call("GET", "/v1/merchants/47.960.950/0001-21", { token });
		expect(first.status).toBe(200);
		const company = await first.json<Record<string, unknown>>();
		expect(company).toMatchObject({ cnpj: "47960950000121", nomeFantasia: "MAGAZINE LUIZA", cnae: "4713004" });
		expect(JSON.stringify(company)).not.toMatch(/PESSOA FISICA|someone@example\.com/);

		const lookups = outbound.filter((url) => url.host === "cnpj.test").length;
		await call("GET", "/v1/merchants/47960950000121", { token });
		expect(outbound.filter((url) => url.host === "cnpj.test").length).toBe(lookups);
	});
});

describe("hourly check", () => {
	it("notices an item refresh once", async () => {
		const token = await pairDevice();
		await call("PUT", "/v1/items", { token, body: { itemIds: [ITEM] } });

		const run = async () => {
			const ctx = createExecutionContext();
			await worker.scheduled(createScheduledController(), env, ctx);
			await waitOnExecutionContext(ctx);
		};
		await run();
		expect(await env.GARDEN.get(`fp:${ITEM}`)).toContain("2026-10-02T06:00:00.000Z");

		pluggyRoutes[`pluggy.test/items/${ITEM}`] = () => Response.json(item(ITEM, "2026-10-03T06:00:00.000Z"));
		await run();
		expect(await env.GARDEN.get(`fp:${ITEM}`)).toContain("2026-10-03T06:00:00.000Z");
	});
});
