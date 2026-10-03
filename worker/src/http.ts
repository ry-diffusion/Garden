/** An error that maps to a JSON response; anything else becomes a 500 with no internals leaked. */
export class HttpError extends Error {
	constructor(
		readonly status: number,
		message: string,
		readonly headers: Record<string, string> = {},
	) {
		super(message);
	}
}

export function json(data: unknown, init: ResponseInit = {}): Response {
	const headers = new Headers(init.headers);
	headers.set("content-type", "application/json; charset=utf-8");
	headers.set("cache-control", "no-store");
	return new Response(JSON.stringify(data), { ...init, headers });
}

export function errorResponse(error: unknown): Response {
	if (error instanceof HttpError) {
		return json({ error: error.message }, { status: error.status, headers: error.headers });
	}
	console.error(JSON.stringify({ event: "unhandled_error", message: error instanceof Error ? error.message : String(error) }));
	return json({ error: "internal_error" }, { status: 500 });
}

/** Parses a small JSON body; request bodies here are a few hundred bytes at most. */
export async function readJson<T>(request: Request, maxBytes = 16_384): Promise<T> {
	const length = Number(request.headers.get("content-length") ?? "0");
	if (length > maxBytes) throw new HttpError(413, "body_too_large");
	const text = await request.text();
	if (text.length > maxBytes) throw new HttpError(413, "body_too_large");
	try {
		return JSON.parse(text) as T;
	} catch {
		throw new HttpError(400, "invalid_json");
	}
}
