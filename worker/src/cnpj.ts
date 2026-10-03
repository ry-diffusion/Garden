import { HttpError } from "./http";

/**
 * CNPJ → company, cached in KV for 30 days. Only company fields are returned; the partners list
 * (`qsa`) and contact data in the registry response are personal data and are dropped here.
 */
export interface Company {
	cnpj: string;
	razaoSocial: string;
	nomeFantasia: string | null;
	cnae: string | null;
	cnaeDescricao: string | null;
	logradouro: string | null;
	numero: string | null;
	bairro: string | null;
	municipio: string | null;
	uf: string | null;
	cep: string | null;
}

const TTL = 30 * 86_400;

export async function lookupCompany(env: Env, raw: string): Promise<Company> {
	const cnpj = raw.replace(/\D/g, "");
	if (cnpj.length !== 14) throw new HttpError(400, "cnpj_must_have_14_digits");

	const cached = await env.GARDEN.get<Company>(`cnpj:${cnpj}`, "json");
	if (cached) return cached;

	const base = (env.CNPJ_API_BASE || "https://brasilapi.com.br/api/cnpj/v1").replace(/\/$/, "");
	const response = await fetch(`${base}/${cnpj}`, { headers: { accept: "application/json" } });
	if (response.status === 404) throw new HttpError(404, "cnpj_not_found");
	if (!response.ok) throw new HttpError(502, "cnpj_registry_unavailable");
	const data = await response.json<Record<string, unknown>>();

	const text = (key: string): string | null => {
		const value = data[key];
		return typeof value === "string" && value.trim() ? value.trim() : null;
	};
	const cnae = typeof data.cnae_fiscal === "number" ? String(data.cnae_fiscal).padStart(7, "0") : text("cnae_fiscal");
	const company: Company = {
		cnpj,
		razaoSocial: text("razao_social") ?? "",
		nomeFantasia: text("nome_fantasia"),
		cnae,
		cnaeDescricao: text("cnae_fiscal_descricao"),
		logradouro: text("logradouro"),
		numero: text("numero"),
		bairro: text("bairro"),
		municipio: text("municipio"),
		uf: text("uf"),
		cep: text("cep"),
	};
	await env.GARDEN.put(`cnpj:${cnpj}`, JSON.stringify(company), { expirationTtl: TTL });
	return company;
}
