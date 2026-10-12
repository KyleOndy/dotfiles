#!/usr/bin/env bash
# Writes mlx-models.yaml's models into alamode's sops catalog as the `local`
# provider, replacing any earlier one. Rerun after changing mlx-models.yaml,
# then `make deploy-trex`. home.nix says why every entry pins thinking off.
# Prints nothing from the catalog: its mcloud ids are private.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
readonly ROOT
readonly SECRETS=$ROOT/nix/secrets/trex.yaml
readonly MLX_MODELS=$ROOT/nix/hosts/trex/mlx-models.yaml

provider=$(yq -o=json "$MLX_MODELS" | jq '{
	baseUrl: "http://\(.server.host):\(.server.port)/v1",
	api: "openai-completions",
	compat: {thinkingFormat: "qwen-chat-template", supportsDeveloperRole: false},
	models: [.models[] | {
		id: .served_model_name,
		name: "\(.served_model_name) (local)",
		reasoning: true,
		thinkingLevelMap: {minimal: null, low: null, medium: null, high: null},
		input: ["text"],
		cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
		contextWindow: .context_length,
		maxTokens: 8192
	}]
}')

# Captured before the write: piped straight into `sops set`, a failed decrypt
# would replace the catalog with an empty string.
catalog=$(sops decrypt --extract '["alamode_models_json"]' "$SECRETS" |
	jq --argjson provider "$provider" '.providers.local = $provider')
jq -Rs . <<<"$catalog" |
	sops set --idempotent --value-stdin "$SECRETS" '["alamode_models_json"]'
