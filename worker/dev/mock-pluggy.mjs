// A local stand-in for the Pluggy API, for developing Garden end-to-end without real credentials.
// Run `npm run dev:mock-pluggy`, set PLUGGY_API_BASE=http://127.0.0.1:8788 in .dev.vars, then `npm run dev`.
//
// Fixtures mirror a real day of Nubank + BTG notifications (names and documents anonymized), so the app can
// reconcile its Apple Pay / notification captures with the "bank postings" that arrive here a day later.
import { createServer } from "node:http";

const PORT = 8788;
const NUBANK_ITEM = "11111111-1111-4111-8111-111111111111";
const BTG_ITEM = "22222222-2222-4222-8222-222222222222";
const ME = { fullName: "Fulano de Tal", document: "123.456.789-00", documentType: "CPF" };
const ME_MASKED = { type: "CPF", value: "***.456.789-**" };

const day = (offset, time = "12:00") => {
	const date = new Date();
	date.setUTCDate(date.getUTCDate() + offset);
	const [h, m] = time.split(":").map(Number);
	date.setUTCHours(h + 3, m, 0, 0); // times are BRT (UTC-3)
	return date.toISOString();
};

const items = {
	[NUBANK_ITEM]: { id: NUBANK_ITEM, status: "UPDATED", executionStatus: "SUCCESS", lastUpdatedAt: day(0, "06:00"), connector: { id: 200, name: "MeuPluggy" } },
	[BTG_ITEM]: { id: BTG_ITEM, status: "UPDATED", executionStatus: "SUCCESS", lastUpdatedAt: day(0, "06:05"), connector: { id: 200, name: "MeuPluggy" } },
};

const accounts = {
	[NUBANK_ITEM]: [
		{ id: "nu-conta", type: "BANK", subtype: "CHECKING_ACCOUNT", number: "1234567-8", name: "Nubank", marketingName: "Nu Conta", balance: 7081.01, currencyCode: "BRL",
			bankData: { transferNumber: "0001/1234567-8" } },
		{ id: "nu-cartao", type: "CREDIT", subtype: "CREDIT_CARD", number: "1234", name: "Nubank", marketingName: "Nubank Ultravioleta", balance: 1702.11, currencyCode: "BRL",
			creditData: { brand: "MASTERCARD", creditLimit: 12000, availableCreditLimit: 10297.89, balanceCloseDate: day(8), balanceDueDate: day(15) } },
	],
	[BTG_ITEM]: [
		{ id: "btg-conta", type: "BANK", subtype: "CHECKING_ACCOUNT", number: "998877", name: "BTG Pactual", marketingName: "Conta BTG", balance: 6500, currencyCode: "BRL",
			bankData: { transferNumber: "0050/998877" } },
	],
};

const pix = (direction, other) => ({
	paymentMethod: "PIX",
	payer: direction === "in" ? other : { name: ME.fullName, documentNumber: ME_MASKED },
	receiver: direction === "in" ? { name: ME.fullName, documentNumber: ME_MASKED } : other,
});

const transactions = {
	"nu-conta": [
		{ id: "nu-t1", date: day(-1, "13:48"), description: "Compra no débito|MINIMERCADOEXEMPL", amount: -19.24, type: "DEBIT", operationType: "CARTAO", status: "POSTED" },
		{ id: "nu-t2", date: day(-1, "16:30"), description: "Compra no débito|MINIMERCADOEXEMPL", amount: -14.49, type: "DEBIT", operationType: "CARTAO", status: "POSTED" },
		{ id: "nu-t3", date: day(-1, "16:33"), description: "Compra no débito|MINIMERCADOEXEMPL", amount: -47.26, type: "DEBIT", operationType: "CARTAO", status: "POSTED" },
		{ id: "nu-t4", date: day(-1, "17:14"), description: "Transferência recebida", amount: 6000, type: "CREDIT", operationType: "PIX", status: "POSTED",
			providerId: "E30306294202610021714PAIR01", paymentData: pix("in", { name: ME.fullName, documentNumber: ME_MASKED, accountNumber: "998877", routingNumberISPB: "30306294" }) },
		{ id: "nu-t5", date: day(-1, "23:15"), description: "Compra no débito|AB RESTAURANTE", amount: -38, type: "DEBIT", operationType: "CARTAO", status: "POSTED",
			merchant: { name: "AB RESTAURANTE", businessName: "AB RESTAURANTE LTDA", cnpj: "00.000.000/0001-91", category: "Eating out" } },
		{ id: "nu-t6", date: day(-4, "10:02"), description: "Saque 24h", amount: -200, type: "DEBIT", operationType: "SAQUE", status: "POSTED" },
		{ id: "nu-t7", date: day(-6, "09:00"), description: "Pagamento de fatura", amount: -1500, type: "DEBIT", operationType: "PAGAMENTO_FATURA", status: "POSTED" },
		{ id: "nu-t8", date: day(0, "08:41"), description: "PADARIA BOM PAO", amount: -12.5, type: "DEBIT", operationType: "CARTAO", status: "PENDING" },
		// As the real Nubank feed sends it: operation|counterpart, Pluggy's generic "Transfers" category, no paymentData.
		{ id: "nu-t9", date: day(-2, "19:05"), description: "Transferência enviada pelo Pix|JOAO PEREIRA", amount: -130, type: "DEBIT", operationType: "PIX", status: "POSTED", category: "Transfers" },
	],
	"nu-cartao": [
		{ id: "nu-c1", date: day(-1, "11:32"), description: "EXEMPLO SOFTWARE, INC.", amount: 28.2, type: "DEBIT", status: "POSTED",
			creditCardMetadata: { payeeMCC: 5734, cardNumber: "1234" }, category: "Digital services" },
		{ id: "nu-c2", date: day(-10, "19:20"), description: "MAGAZINE LUIZA PARC 01/10", amount: 120, type: "DEBIT", status: "POSTED",
			creditCardMetadata: { installmentNumber: 1, totalInstallments: 10, totalAmount: 1200, purchaseDate: day(-10, "19:20"), payeeMCC: 5311, cardNumber: "1234" },
			merchant: { name: "MAGALU", businessName: "MAGAZINE LUIZA S/A", cnpj: "47.960.950/0001-21", category: "Shopping" } },
		{ id: "nu-c3", date: day(-9, "07:00"), description: "IOF COMPRA INTERNACIONAL", amount: 2.1, type: "DEBIT", status: "POSTED", operationType: "TARIFA" },
		{ id: "nu-c4", date: day(-6, "09:00"), description: "Pagamento recebido", amount: -1500, type: "CREDIT", status: "POSTED", operationType: "PAGAMENTO_FATURA" },
		{ id: "nu-c5", date: day(-3, "12:40"), description: "UBER *TRIP", amount: 31.9, type: "DEBIT", status: "POSTED", creditCardMetadata: { payeeMCC: 4121, cardNumber: "1234" } },
	],
	"btg-conta": [
		{ id: "btg-t1", date: day(-1, "05:21"), description: "Pix recebido", amount: 900, type: "CREDIT", operationType: "PIX", status: "POSTED", providerId: "E00000000202610020521AAA01",
			paymentData: pix("in", { name: "Secretaria De Estado Exemplo", documentNumber: { type: "CNPJ", value: "00.000.000/0001-00" } }) },
		{ id: "btg-t2", date: day(-1, "12:18"), description: "Pix enviado", amount: -900, type: "DEBIT", operationType: "PIX", status: "POSTED", providerId: "E30306294202610021218BBB01",
			paymentData: pix("out", { name: "Maria Souza", documentNumber: { type: "CPF", value: "***.111.222-**" }, accountNumber: "55443322", routingNumberISPB: "00360305" }) },
		{ id: "btg-t3", date: day(-1, "16:01"), description: "Pix recebido", amount: 6000, type: "CREDIT", operationType: "PIX", status: "POSTED", providerId: "E00000000202610021601CCC01",
			paymentData: { ...pix("in", { name: "Cliente Exemplo Tecnologia Ltda", documentNumber: { type: "CNPJ", value: "12.345.678/0001-90" } }), reason: "Prestação de serviço" } },
		{ id: "btg-t4", date: day(-1, "17:14"), description: "Pix enviado", amount: -6000, type: "DEBIT", operationType: "PIX", status: "POSTED", providerId: "E30306294202610021714PAIR01",
			paymentData: pix("out", { name: ME.fullName, documentNumber: ME_MASKED, accountNumber: "1234567-8", routingNumberISPB: "18236120" }) },
	],
};

const investments = {
	[NUBANK_ITEM]: [],
	[BTG_ITEM]: [
		{ id: "inv-cdb", name: "CDB Liquidez Diária", type: "FIXED_INCOME", subtype: "CDB", balance: 31000, amount: 31250, status: "ACTIVE" },
		{ id: "inv-tesouro", name: "Tesouro Selic 2029", type: "SECURITY", subtype: "TREASURY", balance: 24300, amount: 24300, status: "ACTIVE", dueDate: "2029-03-01T00:00:00.000Z" },
		{ id: "inv-lci", name: "LCI 95% CDI", type: "FIXED_INCOME", subtype: "LCI", balance: 29000, amount: 29000, status: "ACTIVE", dueDate: day(270) },
	],
};

const PAGE_SIZE = 3;
// MOCK_DROP=nu-t8 node dev/mock-pluggy.mjs — simulate the bank removing a transaction (tombstone test).
const DROPPED = new Set((process.env.MOCK_DROP ?? "").split(",").filter(Boolean));
const send = (res, status, body) => {
	res.writeHead(status, { "content-type": "application/json" });
	res.end(JSON.stringify(body));
};

createServer((req, res) => {
	const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
	const path = url.pathname;
	console.log(req.method, path + url.search);

	if (path === "/auth" && req.method === "POST") return send(res, 200, { apiKey: "mock-api-key" });
	if (req.headers["x-api-key"] !== "mock-api-key") return send(res, 401, { message: "unauthorized" });

	const item = /^\/items\/([^/]+)$/.exec(path);
	if (item) return items[item[1]] ? send(res, 200, items[item[1]]) : send(res, 404, { message: "not found" });

	const itemId = url.searchParams.get("itemId");
	const accountId = url.searchParams.get("accountId");
	if (path === "/accounts") return send(res, 200, { results: accounts[itemId] ?? [] });
	if (path === "/investments") return send(res, 200, { results: investments[itemId] ?? [] });
	if (path === "/loans") return send(res, 200, { results: [] });
	if (path === "/identity") return send(res, 200, { ...ME, addresses: [], phoneNumbers: [] });
	if (path === "/bills") return send(res, 200, { results: [{ id: `${accountId}-bill`, dueDate: day(15), totalAmount: 1702.11 }] });
	if (path === "/v2/transactions") {
		const from = url.searchParams.get("dateFrom") ?? "1970-01-01";
		const all = (transactions[accountId] ?? []).filter((t) => t.date.slice(0, 10) >= from && !DROPPED.has(t.id));
		const offset = Number(url.searchParams.get("after") ?? "0");
		const page = all.slice(offset, offset + PAGE_SIZE);
		const next = offset + PAGE_SIZE < all.length ? String(offset + PAGE_SIZE) : null;
		return send(res, 200, { results: page, next });
	}
	send(res, 404, { message: "not found" });
}).listen(PORT, "127.0.0.1", () => console.log(`mock Pluggy on http://127.0.0.1:${PORT}  items: ${NUBANK_ITEM} (Nubank), ${BTG_ITEM} (BTG)`));
