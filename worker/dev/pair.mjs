// Mints a single-use pairing code for the Garden app.
//   GARDEN_URL=https://garden-api.<you>.workers.dev ADMIN_TOKEN=… npm run pair
// Defaults to the local `wrangler dev` server and the ADMIN_TOKEN in .dev.vars.
import { readFileSync } from "node:fs";

const devVars = (() => {
	try {
		return Object.fromEntries(
			readFileSync(new URL("../.dev.vars", import.meta.url), "utf8")
				.split("\n")
				.filter((line) => line.includes("=") && !line.startsWith("#"))
				.map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]),
		);
	} catch {
		return {};
	}
})();

const base = process.env.GARDEN_URL ?? "http://127.0.0.1:8787";
const admin = process.env.ADMIN_TOKEN ?? devVars.ADMIN_TOKEN;
if (!admin) {
	console.error("Set ADMIN_TOKEN (the same value as the Worker secret).");
	process.exit(1);
}

let response;
try {
	response = await fetch(`${base}/v1/pair/code`, { method: "POST", headers: { authorization: `Bearer ${admin}` } });
} catch {
	console.error(`\n  Não consegui falar com ${base}.`);
	if (!process.env.GARDEN_URL) {
		console.error("  Para o Worker publicado, rode:\n");
		console.error("  GARDEN_URL=https://garden-api.<seu-subdominio>.workers.dev ADMIN_TOKEN=<seu token> npm run pair\n");
		console.error("  (sem GARDEN_URL o script usa o servidor local do `npm run dev`).\n");
	}
	process.exit(1);
}
if (response.status === 401) {
	console.error("\n  ADMIN_TOKEN recusado: use o mesmo valor do `wrangler secret put ADMIN_TOKEN`.\n");
	process.exit(1);
}
if (!response.ok) {
	console.error(`Pairing failed: ${response.status} ${await response.text()}`);
	process.exit(1);
}
const { code, expiresIn } = await response.json();
console.log(`\n  Servidor: ${base}\n  Código:   ${code}   (vale ${Math.round(expiresIn / 60)} min, uma vez)\n`);
console.log("  No Garden: Ajustes ▸ Servidor ▸ Conectar, e cole os dois valores.\n");
