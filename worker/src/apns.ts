import { base64url } from "./crypto";

/**
 * Silent "something changed" pushes via APNs token auth (ES256 JWT signed with Web Crypto).
 * Best effort: the app also syncs on foreground and in background refresh, because iOS throttles
 * silent pushes and drops them for force-quit apps. Disabled unless the APNs secrets are set.
 */
export interface PushRegistration {
	token: string;
	environment: "sandbox" | "production";
}

// Provider JWTs live up to 60 min; reuse for 50. A credential cache, not request state.
let cachedJWT: { keyId: string; jwt: string; issuedAt: number } | undefined;

export function apnsConfigured(env: Env): boolean {
	return Boolean(env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC);
}

async function providerToken(env: Env): Promise<string> {
	const now = Math.floor(Date.now() / 1000);
	if (cachedJWT && cachedJWT.keyId === env.APNS_KEY_ID && now - cachedJWT.issuedAt < 50 * 60) return cachedJWT.jwt;

	const pem = env.APNS_KEY_P8.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
	const der = Uint8Array.from(atob(pem), (char) => char.charCodeAt(0));
	const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);

	const encode = (value: object) => base64url(new TextEncoder().encode(JSON.stringify(value)));
	const unsigned = `${encode({ alg: "ES256", kid: env.APNS_KEY_ID })}.${encode({ iss: env.APNS_TEAM_ID, iat: now })}`;
	// Web Crypto returns ECDSA signatures as raw r‖s — exactly the JWS ES256 format.
	const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
	const jwt = `${unsigned}.${base64url(new Uint8Array(signature))}`;
	cachedJWT = { keyId: env.APNS_KEY_ID, jwt, issuedAt: now };
	return jwt;
}

/** Sends a content-available push to every registered device. Returns how many were accepted. */
export async function pingDevices(env: Env, payload: Record<string, string>): Promise<number> {
	if (!apnsConfigured(env)) return 0;
	const listing = await env.GARDEN.list({ prefix: "push:" });
	const jwt = await providerToken(env);
	let delivered = 0;

	for (const key of listing.keys) {
		const registration = await env.GARDEN.get<PushRegistration>(key.name, "json");
		if (!registration) continue;
		const host = registration.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
		const response = await fetch(`https://${host}/3/device/${registration.token}`, {
			method: "POST",
			headers: {
				authorization: `bearer ${jwt}`,
				"apns-topic": env.APNS_TOPIC,
				"apns-push-type": "background",
				"apns-priority": "5",
			},
			body: JSON.stringify({ aps: { "content-available": 1 }, ...payload }),
		});
		if (response.ok) delivered++;
		else if (response.status === 410) await env.GARDEN.delete(key.name); // token no longer valid
		else console.error(JSON.stringify({ event: "apns_error", status: response.status, reason: await response.text() }));
	}
	return delivered;
}
