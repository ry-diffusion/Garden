/**
 * Single-writer ingestion lease (REVIEW.md C1): only one device turns Pluggy data into ledger rows
 * at a time, so CloudKit never receives two competing copies. KV is eventually consistent (~60 s);
 * for one person's devices that is enough — the app's deterministic ids collapse any rare overlap.
 */
const LEASE_KEY = "lease";
export const LEASE_SECONDS = 600;

interface Lease {
	holder: string;
	expiresAt: number;
}

export async function acquireLease(env: Env, deviceId: string, now = Date.now()): Promise<{ granted: boolean; holder: string; expiresAt: string }> {
	const current = await env.GARDEN.get<Lease>(LEASE_KEY, "json");
	if (current && current.expiresAt > now && current.holder !== deviceId) {
		return { granted: false, holder: current.holder.slice(0, 8), expiresAt: new Date(current.expiresAt).toISOString() };
	}
	const lease: Lease = { holder: deviceId, expiresAt: now + LEASE_SECONDS * 1000 };
	await env.GARDEN.put(LEASE_KEY, JSON.stringify(lease), { expirationTtl: LEASE_SECONDS + 60 });
	return { granted: true, holder: deviceId.slice(0, 8), expiresAt: new Date(lease.expiresAt).toISOString() };
}
