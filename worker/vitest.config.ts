import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
	plugins: [
		cloudflareTest({
			wrangler: { configPath: "./wrangler.jsonc" },
			miniflare: {
				// Test-only values; outbound calls to these hosts are mocked in the tests.
				bindings: {
					PLUGGY_CLIENT_ID: "test-client",
					PLUGGY_CLIENT_SECRET: "test-secret",
					ADMIN_TOKEN: "test-admin-token",
					PLUGGY_API_BASE: "https://pluggy.test",
					CNPJ_API_BASE: "https://cnpj.test",
					APNS_KEY_P8: "",
					APNS_KEY_ID: "",
					APNS_TEAM_ID: "",
				},
			},
		}),
	],
});
