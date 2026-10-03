const encoder = new TextEncoder();

export async function sha256Hex(text: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
	return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function base64url(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function randomToken(byteCount = 32): string {
	return base64url(crypto.getRandomValues(new Uint8Array(byteCount)));
}

/** Pairing codes avoid look-alike characters (0/O, 1/I/L) so they can be typed from a screen. */
export function randomCode(length = 8): string {
	const alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
	const bytes = crypto.getRandomValues(new Uint8Array(length));
	return [...bytes].map((byte) => alphabet[byte % alphabet.length]).join("");
}

/** Constant-time comparison: hash both sides so lengths match, then compare in constant time. */
export async function timingSafeEqual(a: string, b: string): Promise<boolean> {
	const [left, right] = await Promise.all([
		crypto.subtle.digest("SHA-256", encoder.encode(a)),
		crypto.subtle.digest("SHA-256", encoder.encode(b)),
	]);
	return crypto.subtle.timingSafeEqual(left, right);
}
