import { randomCode, randomToken, sha256Hex, timingSafeEqual } from "./crypto";
import { HttpError } from "./http";

/** A paired device. `id` is the SHA-256 of its bearer token — the token itself is never stored. */
export interface Device {
	id: string;
	name: string;
	createdAt: string;
}

const PAIRING_CODE_TTL = 600; // 10 minutes, single use
const PAIR_ATTEMPTS_PER_HOUR = 5;

function bearer(request: Request): string | null {
	const header = request.headers.get("authorization") ?? "";
	const match = /^Bearer\s+(.+)$/i.exec(header);
	return match?.[1]?.trim() || null;
}

export async function authenticate(request: Request, env: Env): Promise<Device> {
	const token = bearer(request);
	if (!token) throw new HttpError(401, "missing_token");
	const id = await sha256Hex(token);
	const device = await env.GARDEN.get<Omit<Device, "id">>(`device:${id}`, "json");
	if (!device) throw new HttpError(401, "invalid_token");
	return { id, ...device };
}

export async function requireAdmin(request: Request, env: Env): Promise<void> {
	const token = bearer(request);
	if (!token || !env.ADMIN_TOKEN || !(await timingSafeEqual(token, env.ADMIN_TOKEN))) {
		throw new HttpError(401, "admin_only");
	}
}

/** Admin-only: a short code the owner types (or scans) into the app. */
export async function createPairingCode(env: Env): Promise<{ code: string; expiresIn: number }> {
	const code = randomCode();
	await env.GARDEN.put(`pair:${code}`, "1", { expirationTtl: PAIRING_CODE_TTL });
	return { code, expiresIn: PAIRING_CODE_TTL };
}

/** Swaps a pairing code for a device token. Rate-limited per IP; the code dies on first use. */
export async function redeemPairingCode(request: Request, env: Env, code: string, deviceName: string): Promise<{ token: string; deviceId: string }> {
	const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
	const rateKey = `rl:pair:${ip}`;
	const attempts = Number((await env.GARDEN.get(rateKey)) ?? "0");
	if (attempts >= PAIR_ATTEMPTS_PER_HOUR) throw new HttpError(429, "too_many_attempts", { "retry-after": "3600" });
	await env.GARDEN.put(rateKey, String(attempts + 1), { expirationTtl: 3600 });

	const normalized = code.trim().toUpperCase();
	if (!/^[A-Z0-9]{6,12}$/.test(normalized) || !(await env.GARDEN.get(`pair:${normalized}`))) {
		throw new HttpError(401, "invalid_code");
	}
	await env.GARDEN.delete(`pair:${normalized}`);

	const token = randomToken();
	const deviceId = await sha256Hex(token);
	const device: Omit<Device, "id"> = { name: deviceName.slice(0, 64) || "Garden", createdAt: new Date().toISOString() };
	await env.GARDEN.put(`device:${deviceId}`, JSON.stringify(device));
	return { token, deviceId };
}

export async function revokeDevice(env: Env, device: Device): Promise<void> {
	await Promise.all([env.GARDEN.delete(`device:${device.id}`), env.GARDEN.delete(`push:${device.id}`)]);
}
