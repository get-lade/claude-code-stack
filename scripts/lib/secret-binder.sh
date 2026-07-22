#!/usr/bin/env bash
# Secret-binder (ADR-035): wires a tenant's Cloudflare Secrets Store secrets
# into a Worker's wrangler config as [[secrets_store_secrets]] bindings.
# Bind-only — the provisioner never reads plaintext; bindings reference the
# store id + secret NAME, so the emitted block is committed and reviewable.
# Sourced by deploy scripts (same pattern as tier-installer.sh): functions
# only, callers own set -uo pipefail, errors on stderr, fail HARD — a deploy
# missing its secret bindings must not continue.

# Hardcoded on purpose: the bearer token is sent to this host, so it must
# not be redirectable via env. Tests mock cf_api_get itself, not the base.
CF_API_BASE="https://api.cloudflare.com/client/v4"

# The ONLY function that talks to the CF API (plan §6.3: isolate the beta-era
# API surface to one place; tests override this function to serve fixtures).
# Token comes from $CF_API_TOKEN via a --config stdin file — never on argv.
# xtrace is suppressed around the token-bearing lines so a caller's set -x
# cannot echo plaintext to logs (same rationale as openai-review.sh).
cf_api_get() {
  local path="$1"
  local had_xtrace=0
  [[ $- == *x* ]] && had_xtrace=1
  { set +x; } 2>/dev/null
  printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" \
    | curl -sS --config - "${CF_API_BASE}${path}"
  local rc=$?
  [[ "$had_xtrace" == 1 ]] && set -x
  return $rc
}

# Resolution order for the tenant API token (plan §2 — the store copy is for
# the running Worker; the provisioner holds its own separately-saved copy):
# env <TENANT>_API_TOKEN, then macOS Keychain, then fail with the exact
# command to run. Sets CF_API_TOKEN; prints nothing. xtrace suppressed —
# every branch here touches a plaintext token.
resolve_tenant_token() {
  local tenant_id="$1"
  local keychain_item="$2"
  local had_xtrace=0
  [[ $- == *x* ]] && had_xtrace=1
  { set +x; } 2>/dev/null

  # Keychain item names are operator-facing (pasted into security(1) calls)
  # and tenant-supplied — hold them to a safe charset.
  if [[ -n "$keychain_item" && ! "$keychain_item" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "    [bind-fail] api_token_keychain_item has unsafe characters: $keychain_item" >&2
    [[ "$had_xtrace" == 1 ]] && set -x
    return 1
  fi

  local env_name
  env_name="$(echo "$tenant_id" | tr 'a-z-' 'A-Z_')_API_TOKEN"
  if [[ -n "${!env_name:-}" ]]; then
    CF_API_TOKEN="${!env_name}"
    [[ "$had_xtrace" == 1 ]] && set -x
    return 0
  fi

  if [[ -n "$keychain_item" ]]; then
    local from_keychain
    from_keychain="$(security find-generic-password -s "$keychain_item" -w 2>/dev/null || echo "")"
    if [[ -n "$from_keychain" ]]; then
      CF_API_TOKEN="$from_keychain"
      [[ "$had_xtrace" == 1 ]] && set -x
      return 0
    fi
  fi

  echo "    [requirement-fail] No token for tenant '$tenant_id': env $env_name unset and Keychain item '${keychain_item:-<none configured>}' missing" >&2
  echo "    Add with: security add-generic-password -s '${keychain_item:-${tenant_id}-cf-api-token}' -a \"\$USER\" -w '<token>' -U" >&2
  [[ "$had_xtrace" == 1 ]] && set -x
  return 1
}

# Resolve the tenant's Secrets Store id from the ACCOUNT id, always live.
# NEVER accept a store id from config — ADR-035 gotcha: account id and store
# id are distinct 32-hex values, and a store id in the accounts/{id} slot
# returns a misleading 10000 auth error, not a 404.
resolve_store_id() {
  local account_id="$1"

  local resp
  resp="$(cf_api_get "/accounts/$account_id/secrets_store/stores")" || {
    echo "  [bind-fail] list-stores request failed for account $account_id" >&2
    return 1
  }

  if jq -e '.errors[]? | select(.code == 10000)' <<<"$resp" >/dev/null 2>&1; then
    echo "  [bind-fail] 10000 Authentication error from list-stores. Two known causes:" >&2
    echo "    - '$account_id' is not the ACCOUNT id (a Secrets Store id in the accounts/{id} slot returns this misleading error, not a 404 — ADR-035)" >&2
    echo "    - token lacks the explicit 'Secrets Store: Read' account permission (not in default hosting scopes)" >&2
    return 1
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    echo "  [bind-fail] list-stores error: $(jq -c '.errors // "unparseable response"' <<<"$resp" 2>/dev/null)" >&2
    return 1
  fi

  local count
  count="$(jq '.result | length' <<<"$resp")" || return 1
  if [[ "$count" -eq 0 ]]; then
    echo "  [bind-fail] No Secrets Store found in account $account_id" >&2
    return 1
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "  [bind-fail] $count Secrets Stores in account $account_id — ambiguous, refusing to guess (plan §6.4). Stores:" >&2
    jq -r '.result[] | "    \(.id)  \(.name // "")"' <<<"$resp" >&2
    return 1
  fi

  jq -r '.result[0].id' <<<"$resp"
}

# Preflight gate: every expected name must exist in the store. The name→id
# resolution is validation only — the wrangler binding references the NAME.
# All misses reported, not first-fail. 'pending' status is NOT a failure
# (secrets show Pending until first bound).
resolve_secret_names() {
  local account_id="$1"
  local store_id="$2"
  shift 2

  local page=1 existing="" resp total_pages
  while :; do
    resp="$(cf_api_get "/accounts/$account_id/secrets_store/stores/$store_id/secrets?page=$page&per_page=100")" || {
      echo "  [bind-fail] list-secrets request failed (page $page)" >&2
      return 1
    }
    if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
      echo "  [bind-fail] list-secrets error: $(jq -c '.errors // "unparseable response"' <<<"$resp" 2>/dev/null)" >&2
      return 1
    fi
    existing+="$(jq -r '.result[]?.name' <<<"$resp")"$'\n'
    total_pages="$(jq -r '.result_info.total_pages // 1' <<<"$resp")"
    [[ "$page" -ge "$total_pages" ]] && break
    page=$((page + 1))
  done

  local name missing=0
  for name in "$@"; do
    if ! grep -qxF "$name" <<<"$existing"; then
      echo "  [bind-fail] Secret '$name' not found in store $store_id" >&2
      missing=$((missing + 1))
    fi
  done
  [[ "$missing" -gt 0 ]] && return 1
  return 0
}

# Pure function, no API calls: the [[secrets_store_secrets]] block on stdout.
# binding = secret_name = the tenant-prefixed name (one name, one identifier,
# no aliasing — the Worker reads env.<NAME>).
emit_secret_bindings() {
  local store_id="$1"
  shift

  local name
  for name in "$@"; do
    cat <<EOF
[[secrets_store_secrets]]
binding = "$name"
store_id = "$store_id"
secret_name = "$name"

EOF
  done
}

# Idempotent marker-region splice (TOML-comment twin of append_stack_section).
replace_secrets_region() {
  local content_file="$1"
  local target="$2"

  local marker="# STACK_SECRETS_MANAGED"
  local end_marker="# /STACK_SECRETS_MANAGED"

  if grep -qxF "$marker" "$target" 2>/dev/null; then
    # Exactly one well-ordered pair — duplicate, missing, or out-of-order
    # markers would make the awk state machine silently drop real config.
    local starts ends start_line end_line
    starts="$(grep -cxF "$marker" "$target")"
    ends="$(grep -cxF "$end_marker" "$target")"
    start_line="$(grep -nxF "$marker" "$target" | head -1 | cut -d: -f1)"
    end_line="$(grep -nxF "$end_marker" "$target" | head -1 | cut -d: -f1)"
    if [[ "$starts" != 1 || "$ends" != 1 || "$start_line" -ge "${end_line:-0}" ]]; then
      echo "  [bind-fail] $target has a malformed STACK_SECRETS_MANAGED region (need exactly one start/end pair, start before end)" >&2
      return 1
    fi
    awk -v source="$content_file" -v marker="$marker" -v end_marker="$end_marker" '
      BEGIN { in_section = 0 }
      $0 == end_marker { in_section = 0; print; next }
      $0 == marker { in_section = 1; print; while ((getline line < source) > 0) print line; next }
      !in_section { print }
    ' "$target" > "$target.new" || return 1
    mv "$target.new" "$target" || return 1
  else
    # Build-to-temp then atomic mv — a mid-write failure must not leave an
    # unclosed managed region in the committed config.
    {
      cat "$target" 2>/dev/null
      echo ""
      echo "$marker"
      cat "$content_file"
      echo "$end_marker"
    } > "$target.new" || { rm -f "$target.new"; return 1; }
    mv "$target.new" "$target" || return 1
  fi
}

# Orchestrator — the only entrypoint deploy scripts call.
#   bind_tenant_secrets <tenant_json_path> <wrangler_toml_path>
bind_tenant_secrets() {
  local tenant_json="$1"
  local wrangler_toml="$2"

  if ! jq -e . "$tenant_json" >/dev/null 2>&1; then
    echo "  [bind-fail] tenant.json missing or unparseable: $tenant_json" >&2
    return 1
  fi

  local tenant_id account_id keychain_item
  tenant_id="$(jq -r '.tenant_id // empty' "$tenant_json")"
  account_id="$(jq -r '.deploy.cloudflare.account_id // empty' "$tenant_json")"
  keychain_item="$(jq -r '.deploy.cloudflare.api_token_keychain_item // empty' "$tenant_json")"

  # Defense-in-depth: re-assert the schema patterns at runtime — these values
  # feed env-var construction, URL paths, and Keychain lookups, and callers
  # may not have schema-validated the file.
  if [[ ! "$tenant_id" =~ ^[a-z][a-z0-9-]{1,62}$ ]]; then
    echo "  [bind-fail] tenant.json tenant_id missing or invalid" >&2
    return 1
  fi

  # .secrets must be an array — a malformed field must fail closed, never
  # read as "no secrets declared" (that would be a silent zero-bindings
  # deploy). Explicitly empty [] is the only legitimate no-op.
  if ! jq -e '(.secrets // []) | type == "array"' "$tenant_json" >/dev/null 2>&1; then
    echo "  [bind-fail] tenant.json .secrets is not an array — refusing to treat as empty" >&2
    return 1
  fi

  local -a names=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && names+=("$line")
  done < <(jq -r '(.secrets // [])[]' "$tenant_json")

  if [[ "${#names[@]}" -eq 0 ]]; then
    echo "  [bind] No secrets declared for tenant '$tenant_id' — nothing to bind."
    return 0
  fi

  if [[ ! "$account_id" =~ ^[0-9a-f]{32}$ ]]; then
    echo "  [bind-fail] tenant.json declares secrets but deploy.cloudflare.account_id is missing or not a 32-hex account id" >&2
    return 1
  fi

  # Names are interpolated into TOML string literals and API URLs: enforce
  # the schema charset (^[A-Z][A-Z0-9_]*$) — blocks quote/newline breakout —
  # AND the tenant prefix (ADR-034/035 convention).
  local prefix name
  prefix="$(echo "$tenant_id" | tr 'a-z-' 'A-Z_')_"
  for name in "${names[@]}"; do
    if [[ ! "$name" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      echo "  [bind-fail] Secret name has unsafe characters (must match ^[A-Z][A-Z0-9_]*\$): ${name:0:40}" >&2
      return 1
    fi
    if [[ "$name" != "$prefix"* ]]; then
      echo "  [bind-fail] Secret '$name' does not carry the tenant prefix '$prefix'" >&2
      return 1
    fi
  done

  resolve_tenant_token "$tenant_id" "$keychain_item" || return 1

  local store_id
  store_id="$(resolve_store_id "$account_id")" || return 1

  resolve_secret_names "$account_id" "$store_id" "${names[@]}" || return 1

  local block
  block="$(mktemp)" || return 1
  emit_secret_bindings "$store_id" "${names[@]}" > "$block" || { rm -f "$block"; return 1; }
  touch "$wrangler_toml" || { rm -f "$block"; return 1; }
  replace_secrets_region "$block" "$wrangler_toml" || { rm -f "$block"; return 1; }
  rm -f "$block"

  echo "  [bind] ${#names[@]} secret binding(s) for tenant '$tenant_id' written to $wrangler_toml"
}
