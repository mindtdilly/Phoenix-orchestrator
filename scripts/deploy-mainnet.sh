#!/usr/bin/env bash
# =============================================================================
# PhoenixToken — MAINNET deploy (graduation variant of deploy.sh)
#
#   1. Uncomment the [sncast.mainnet] profile in snfoundry.toml and set:
#        account = a NEW mainnet-only deployer account (hot, minimally funded)
#        url     = your OWN RPC (Infura/Alchemy) — never a public endpoint
#   2. Create the multisig FIRST (Argent Multisig or Braavos w/ hardware signer)
#      — it must exist on mainnet BEFORE this script runs; it becomes `owner`.
#   3. export MAINNET_ACK="I understand this spends real STRK"
#      export MAINNET_RPC_URL="https://starknet-mainnet.infura.io/v3/<KEY>"
#      OWNER=0x<multisig> RECIPIENT=0x<multisig> ./deploy-mainnet.sh
#
# Differences vs the Sepolia script, by design:
#   - refuses to run without explicit ack + dedicated RPC + multisig owner
#   - owner/recipient CANNOT silently default to the hot deployer account
#   - verifies the multisig address is a live contract BEFORE deploying
#   - every irreversible step requires a typed confirmation
#   - post-deploy: prints the handoff checklist (verify owner, fund-out,
#     rotate deployer out of every ops path)
#
# State cache: .deploy-state-mainnet/ (gitignore it). Idempotent like its
# testnet sibling — safe to re-run; completed steps are skipped.
#
# Requires: sncast, scarb, jq, curl. No private keys in this file. Ever.
# =============================================================================
set -euo pipefail

PROFILE="mainnet"
ACCOUNT_NAME="${ACCOUNT_NAME:-phoenix-mainnet}"
CONTRACT_NAME="${CONTRACT_NAME:-PhoenixToken}"
STATE_DIR=".deploy-state-mainnet"
ACCOUNT_ADDR_FILE="$STATE_DIR/account_address"
CLASS_HASH_FILE="$STATE_DIR/class_hash"
CONTRACT_ADDR_FILE="$STATE_DIR/contract_address"
OWNER="${OWNER:-}"
RECIPIENT="${RECIPIENT:-}"

say()  { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {  # typed confirmation — this is mainnet, not a loop-friendly testnet
  local prompt="$1"
  printf '\033[1;33m%s\033[0m Type "yes" to continue: ' "$prompt"
  read -r ans
  [ "$ans" = "yes" ] || die "aborted by operator"
}

# =============================================================================
# GATE 0 — hard preconditions (all fail-fast, before touching the network)
# =============================================================================
say "GATE 0: mainnet preconditions"

[ "${MAINNET_ACK:-}" = "I understand this spends real STRK" ] \
  || die 'export MAINNET_ACK="I understand this spends real STRK" first'

[ -n "${MAINNET_RPC_URL:-}" ] \
  || die 'export MAINNET_RPC_URL=<your own Infura/Alchemy mainnet RPC> — public endpoints are not acceptable for mainnet'
echo "$MAINNET_RPC_URL" | grep -qiE 'infura|alchemy|your-domain' \
  || warn "RPC doesn't look like a dedicated provider — double-check it's YOUR endpoint, not a public one"

[ -n "$OWNER" ]     || die "OWNER is required (multisig address). Refusing to default to a hot account."
[ -n "$RECIPIENT" ] || die "RECIPIENT is required (treasury address, typically the multisig). Refusing to default."
[ "$OWNER" != "$ACCOUNT_NAME" ] || die "sanity: OWNER looks like an account name, not an address"

for t in sncast scarb jq curl; do
  command -v "$t" >/dev/null 2>&1 || die "missing '$t'"
done
[ -f Scarb.toml ]     || die "run from the contract dir (Scarb.toml not found)"
[ -f snfoundry.toml ] || die "snfoundry.toml missing — uncomment the [sncast.mainnet] profile first"
grep -q '\[sncast.mainnet\]' snfoundry.toml || die "[sncast.mainnet] profile is still commented out in snfoundry.toml"

mkdir -p "$STATE_DIR"

# =============================================================================
# GATE 1 — multisig must be a live, verified contract BEFORE we mint to it
# =============================================================================
say "GATE 1: verifying multisig owner $OWNER exists on mainnet"
OWNER_CLASS="$(sncast --profile "$PROFILE" call \
  --contract-address "$OWNER" --function get_threshold 2>/dev/null || true)"
if [ -n "$OWNER_CLASS" ]; then
  ok "multisig responds to get_threshold: $OWNER_CLASS"
else
  warn "get_threshold probe failed — trying get_signers (Argent) ..."
  sncast --profile "$PROFILE" call \
    --contract-address "$OWNER" --function get_signers 2>/dev/null | grep -q . \
    || die "owner $OWNER does not respond like a multisig. Create it FIRST (Argent Multisig / Braavos) and re-run."
  ok "multisig responds to get_signers"
fi
warn "Confirm signer set + threshold on Voyager BEFORE proceeding:"
warn "  https://voyager.online/contract/$OWNER"
confirm "Multisig signer set and threshold verified on Voyager?"

# =============================================================================
# Phase 3M — deployer account (hot, minimal funds, mainnet-only)
# =============================================================================
say "Phase 3M: deployer account '$ACCOUNT_NAME'"

if sncast account list --profile "$PROFILE" 2>/dev/null | grep -q "$ACCOUNT_NAME"; then
  ok "deployer account exists — skipping create"
else
  warn "creating a NEW mainnet deployer account. Fund it with ONLY what this deploy needs"
  warn "(declare + deploy fees + buffer). Treasury/owner funds live in the multisig, NOT here."
  confirm "Create mainnet deployer account?"
  CREATE_OUT="$(sncast account create --name "$ACCOUNT_NAME" --type oz --profile "$PROFILE" 2>&1)" \
    || die "account create failed:\n$CREATE_OUT"
  echo "$CREATE_OUT"
  echo "$CREATE_OUT" | grep -oiE '0x[0-9a-f]{40,64}' | head -1 > "$ACCOUNT_ADDR_FILE"
  warn "Fund $(cat "$ACCOUNT_ADDR_FILE") with a MINIMAL amount of real STRK, then re-run."
  exit 0
fi

if [ ! -s "$ACCOUNT_ADDR_FILE" ]; then
  ADDR="$(sncast account list --profile "$PROFILE" 2>/dev/null \
          | grep -A3 "$ACCOUNT_NAME" | grep -oiE '0x[0-9a-f]{40,64}' | head -1 || true)"
  [ -n "$ADDR" ] || die "could not resolve deployer address"
  echo "$ADDR" > "$ACCOUNT_ADDR_FILE"
fi
ACCOUNT_ADDR="$(cat "$ACCOUNT_ADDR_FILE")"
ok "deployer: $ACCOUNT_ADDR"
[ "$OWNER" != "$ACCOUNT_ADDR" ] || die "OWNER must be the multisig, not the hot deployer"

if sncast --profile "$PROFILE" --account "$ACCOUNT_NAME" \
     call --contract-address "$ACCOUNT_ADDR" --function get_nonce 2>/dev/null | grep -q .; then
  ok "deployer already on-chain — skipping account deploy"
else
  confirm "Deploy the mainnet account contract (spends real STRK)?"
  sncast account deploy --profile "$PROFILE" --name "$ACCOUNT_NAME" --silent \
    || die "account deploy failed — underfunded deployer?"
  ok "deployer account live"
fi

# =============================================================================
# Phase 4M — build (byte-identical to what you tested on Sepolia, ideally)
# =============================================================================
say "Phase 4M: scarb build"
warn "Mainnet rule: this SHOULD be the exact source you deployed + verified on Sepolia."
[ -f src/lib.cairo ] || die "src/lib.cairo missing"
scarb build
CLASS_JSON="target/dev/$(basename "$PWD")_${CONTRACT_NAME}.contract_class.json"
[ -f "$CLASS_JSON" ] || die "artifact not found: $CLASS_JSON"
sha256sum "$CLASS_JSON" | tee "$STATE_DIR/artifact.sha256"
ok "artifact hash recorded — diff this against your Sepolia artifact if you want proof of identity"

# =============================================================================
# Phase 5M — declare
# =============================================================================
say "Phase 5M: declare $CONTRACT_NAME on MAINNET"
if [ -s "$CLASS_HASH_FILE" ]; then
  ok "already declared (cached): $(cat "$CLASS_HASH_FILE")"
else
  confirm "Declare contract class on mainnet (spends real STRK)?"
  DECLARE_OUT="$(sncast --profile "$PROFILE" --account "$ACCOUNT_NAME" \
                   declare --contract-name "$CONTRACT_NAME" 2>&1)" || {
    echo "$DECLARE_OUT" | grep -qi "already declared" \
      || die "declare failed:\n$DECLARE_OUT"
    warn "class already declared on-chain — recovering hash"
  }
  echo "$DECLARE_OUT"
  HASH="$(echo "$DECLARE_OUT" | grep -i 'class_hash' | grep -oiE '0x[0-9a-f]{40,64}' | head -1)"
  [ -n "${HASH:-}" ] || die "no class_hash in output — paste it into $CLASS_HASH_FILE manually"
  echo "$HASH" > "$CLASS_HASH_FILE"
  ok "class_hash: $HASH"
fi
CLASS_HASH="$(cat "$CLASS_HASH_FILE")"

# =============================================================================
# Phase 6M — deploy with multisig owner, verify, handoff
# =============================================================================
say "Phase 6M: deploy"
echo "    class:     $CLASS_HASH"
echo "    recipient: $RECIPIENT"
echo "    owner:     $OWNER  (multisig)"
if [ -s "$CONTRACT_ADDR_FILE" ]; then
  ok "already deployed (cached): $(cat "$CONTRACT_ADDR_FILE")"
else
  confirm "FINAL STEP — deploy PhoenixToken to mainnet with the parameters above?"
  DEPLOY_OUT="$(sncast --profile "$PROFILE" --account "$ACCOUNT_NAME" \
                  deploy --class-hash "$CLASS_HASH" \
                  --arguments "$RECIPIENT,$OWNER" 2>&1)" \
    || die "deploy failed:\n$DEPLOY_OUT"
  echo "$DEPLOY_OUT"
  CADDR="$(echo "$DEPLOY_OUT" | grep -i 'contract_address' | grep -oiE '0x[0-9a-f]{40,64}' | head -1)"
  [ -n "${CADDR:-}" ] || die "no contract_address in output — paste it into $CONTRACT_ADDR_FILE"
  echo "$CADDR" > "$CONTRACT_ADDR_FILE"
  ok "contract_address: $CADDR"
fi
CONTRACT_ADDR="$(cat "$CONTRACT_ADDR_FILE")"

say "Verify on-chain:"
# sncast call is a view (no tx) — account is optional. Never pass the contract
# address as --account; that was the previous syntax bug.
sncast --profile "$PROFILE" call \
  --contract-address "$CONTRACT_ADDR" --function name || warn "name() failed"

OWNER_OUT="$(sncast --profile "$PROFILE" call \
  --contract-address "$CONTRACT_ADDR" --function owner 2>&1)" && {
  echo "$OWNER_OUT"
  OWNER_HEX="${OWNER#0x}"; OWNER_HEX="${OWNER_HEX#0X}"
  echo "$OWNER_OUT" | grep -qiE "0x0*${OWNER_HEX}" \
    && ok "owner() == $OWNER (multisig)" \
    || warn "owner() responded but did not match $OWNER — check Voyager before handoff"
} || {
  warn "owner() call failed — trying balance_of($RECIPIENT)"
  sncast --profile "$PROFILE" call \
    --contract-address "$CONTRACT_ADDR" --function balance_of --arguments "$RECIPIENT" \
    || warn "read-back calls failed — verify manually on Voyager"
}

cat <<EOF

$(ok "MAINNET DEPLOY COMPLETE") 🎓🔥

  Contract: https://voyager.online/contract/$CONTRACT_ADDR
  Owner:    https://voyager.online/contract/$OWNER

HANDOFF CHECKLIST — do these NOW, in order:
  [ ] 1. On Voyager, confirm owner() == $OWNER (the multisig), not the deployer
  [ ] 2. Confirm the mint Transfer event went to recipient $RECIPIENT
  [ ] 3. Drain remaining STRK from the hot deployer ($ACCOUNT_ADDR) back to
         the multisig — the deployer should end near-zero
  [ ] 4. Remove the mainnet accounts-file entry from any synced/backed-up
         location; the multisig is the control plane from here on
  [ ] 5. All future admin actions (mint/transfer-ownership/pauses) go through
         the multisig flow — this hot account has served its purpose
  [ ] 6. Archive this state dir + artifact.sha256 with your deployment records
EOF
