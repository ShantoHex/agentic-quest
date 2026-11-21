#!/usr/bin/env bash
# Agentic Quest — mainnet launch helper (BNB Smart Chain, chainId 56).
# NOTHING runs without CONFIRM=yes: every step sends real mainnet transactions from the deployer (owner) wallet.
#
# Required flow: deploy, then golive. No pre-made quest is created; publish from the site after go-live.
#   CONFIRM=yes scripts/launch-mainnet.sh deploy                       # deploy QuestRewards v5 + Sourcify verify + setSigner(mainnet signer)
#   CONFIRM=yes scripts/launch-mainnet.sh golive                       # NETWORK=mainnet on Vercel + redeploy via git push (never `vercel deploy` from web/)
#
# Optional — only if you want to create/fund a quest from this script instead of the Publish page:
#   CONFIRM=yes scripts/launch-mainnet.sh campaign fcfs 0.10 50 <xPostId|-> "<title>" <budgetUSDT> [endUnix]
#   CONFIRM=yes scripts/launch-mainnet.sh campaign random "0.05:30,0.10:50,0.20:20" 100 <xPostId|-> "<title>" <budgetUSDT> [endUnix]
#        (exact approve of <budget> + createQuest: creates AND funds. Rewards >= 0.05 each, no max; RANDOM = 1-5 "amount:chance%" tiers summing
#         to 100; budget >= 0.1 and >= one claim (largest tier); "-" = set the X post later with setTargetPost. MAX_TRANCHE caps this script only)
#   CONFIRM=yes scripts/launch-mainnet.sh fund <campaignId> <usdt>     # one small tranche (<= MAX_TRANCHE, default 25)
#
# Keys: the deployer/owner key is loaded from secrets/deployer.json into an env var only (never printed).
# The voucher signer is a SEPARATE key that exists only in Vercel (SIGNER_PRIVATE_KEY_MAINNET); only its
# address is used here (deployments/mainnet-signer-address.txt).
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
RPC=${RPC:-https://bsc-dataseed.bnbchain.org}
REGISTRY=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
USDT=0x55d398326f99059fF775485246999027B3197955
OUT=deployments/mainnet.json
GAS=(--gas-price "${GAS_PRICE:-0.1gwei}")

if [ "${CONFIRM:-}" != "yes" ]; then sed -n 2,18p "$0"; echo "Refusing: set CONFIRM=yes (real mainnet transactions)."; exit 1; fi
[ "$(cast chain-id --rpc-url "$RPC")" = "56" ] || { echo "RPC is not chain 56"; exit 1; }
PK=$(python3 -c "import json;print(json.load(open('${DEPLOYER_JSON:-/workspace/secrets/deployer.json}'))['data'][0]['private_key'])")
export PK
OWNER=$(cast wallet address --private-key "$PK")
SIGNER=$(tr -d '[:space:]' < deployments/mainnet-signer-address.txt)
[ "${SIGNER,,}" != "${OWNER,,}" ] || { echo "Signer must differ from owner"; exit 1; }
qr() { python3 -c "import json;print(json.load(open('$OUT'))['QuestRewards'])"; }
need_bnb() { # $1 = min wei
  local b; b=$(cast balance "$OWNER" --rpc-url "$RPC")
  if [ "$(python3 -c "print(int($b) < int($1))")" = "True" ]; then
    echo "Insufficient BNB on $OWNER: have $(cast from-wei "$b") need >= $(cast from-wei "$1")"; exit 1; fi
}

case "${1:-}" in
deploy)
  [ ! -f "$OUT" ] || { echo "$OUT exists; already deployed"; exit 1; }
  need_bnb 600000000000000   # 0.0006 BNB (v5 deploy ~4.06M gas + setSigner ~48k on testnet; at 0.1 gwei = ~0.00041)
  forge build >/dev/null
  ADDR=$(forge create src/QuestRewards.sol:QuestRewards --rpc-url "$RPC" --private-key "$PK" "${GAS[@]}" --broadcast --json \
        --constructor-args "$REGISTRY" "$USDT" "$OWNER" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
  echo "QuestRewards: $ADDR"
  forge verify-contract "$ADDR" src/QuestRewards.sol:QuestRewards --chain 56 --verifier sourcify \
        --constructor-args "$(cast abi-encode 'c(address,address,address)' "$REGISTRY" "$USDT" "$OWNER")" || echo "verify: retry later"
  cast send "$ADDR" "setSigner(address)" "$SIGNER" --rpc-url "$RPC" --private-key "$PK" "${GAS[@]}" >/dev/null
  [ "$(cast call "$ADDR" 'signer()(address)' --rpc-url "$RPC")" = "$SIGNER" ] || { echo "signer mismatch"; exit 1; }
  [ "$(cast call "$ADDR" 'EIP712_VERSION()(string)' --rpc-url "$RPC")" = '"2"' ] || { echo "unexpected contract version"; exit 1; }
  printf '{"chainId":56,"QuestRewards":"%s","version":"v5-tiers","eip712Version":"2","owner":"%s","signer":"%s","agentIdRegistry":"%s","usdt":"%s"}\n' \
    "$ADDR" "$OWNER" "$SIGNER" "$REGISTRY" "$USDT" > "$OUT"
  sed -i "/key: \"mainnet\"/,/mockRegistry/ s#questRewards: \"[^\"]*\"#questRewards: \"$ADDR\"#" web/api/_networks.ts
  echo "Wrote $OUT and web/api/_networks.ts. Next: golive (campaign/fund are optional; publish from the site if you prefer)." ;;
campaign)
  MODE=${2:?fcfs|random}; REWARD=${3:?amount (fcfs) or tiers "a:c,a:c" (random)}; SLOTS=${4:?slots}; POST=${5:?xPostId or -}; TITLE=${6:?title}; BUDGET=${7:?budgetUSDT}; END=${8:-0}
  [ "$POST" = "-" ] && POST=""
  # Validate locally (the contract enforces the same rules): rewards >= 0.05, no max; tiers 1-5, chances sum 100; budget >= 0.1 and >= one claim.
  ARGS=$(python3 - "$MODE" "$REWARD" "$BUDGET" "${MAX_TRANCHE:-25}" <<'PY'
import sys
from decimal import Decimal as D
mode, reward, budget, cap = sys.argv[1], sys.argv[2], D(sys.argv[3]), D(sys.argv[4])
wei = lambda x: int(D(x) * 10**18)
if budget > cap: sys.exit(f"Budget > MAX_TRANCHE ({cap} USDT); start small and top up with fund")
if mode == "fcfs":
    if D(reward) < D("0.05"): sys.exit("FCFS reward must be >= 0.05")
    m, a, amts, chs, unit = 1, wei(reward), [], [], D(reward)
elif mode == "random":
    tiers = [t.split(":") for t in reward.split(",") if t]
    if not 1 <= len(tiers) <= 5: sys.exit("RANDOM needs 1-5 tiers like 0.05:30,0.10:50,0.20:20")
    amts = [D(a) for a, _ in tiers]; chs = [int(c) for _, c in tiers]
    if min(amts) < D("0.05"): sys.exit("each tier must be >= 0.05")
    if min(chs) < 1 or sum(chs) != 100: sys.exit("tier chances must be whole numbers >= 1 that sum to 100")
    m, a, unit = 0, 0, max(amts)
    amts = [wei(x) for x in amts]
else:
    sys.exit("mode must be fcfs or random")
if budget < D("0.1") or budget < unit: sys.exit(f"budget must be >= 0.1 and >= one claim ({unit})")
print(m, a, "[" + ",".join(map(str, amts)) + "]", "[" + ",".join(map(str, chs)) + "]", wei(budget))
PY
) || exit 1
  read -r M A TA TC B <<< "$ARGS"
  need_bnb 50000000000000
  cast send "$USDT" "approve(address,uint256)" "$(qr)" "$B" --rpc-url "$RPC" --private-key "$PK" "${GAS[@]}" >/dev/null
  cast send "$(qr)" "createQuest(uint8,uint256,uint256[],uint8[],uint32,uint64,string,string,uint256)" "$M" "$A" "$TA" "$TC" "$SLOTS" "$END" "$POST" "$TITLE" "$B" \
    --rpc-url "$RPC" --private-key "$PK" "${GAS[@]}" >/dev/null
  echo "Created campaign #$(cast call "$(qr)" 'campaignCount()(uint256)' --rpc-url "$RPC")" ;;
fund)
  ID=${2:?campaignId}; AMT=${3:?usdt}; W=$(cast to-wei "$AMT")
  python3 -c "import sys; sys.exit(0 if float('$AMT') <= float('${MAX_TRANCHE:-25}') else 1)" \
    || { echo "Tranche > MAX_TRANCHE (${MAX_TRANCHE:-25} USDT); fund in small tranches"; exit 1; }
  need_bnb 50000000000000
  cast send "$USDT" "approve(address,uint256)" "$(qr)" "$W" --rpc-url "$RPC" --private-key "$PK" "${GAS[@]}" >/dev/null
  cast send "$(qr)" "fundCampaign(uint256,uint256)" "$ID" "$W" --rpc-url "$RPC" --private-key "$PK" "${GAS[@]}" >/dev/null
  echo "Funded campaign $ID with $AMT USDT" ;;
golive)
  python3 -c "import re;s=open('web/api/_networks.ts').read();assert re.search(r'key: \"mainnet\"[\s\S]*?questRewards: \"0x[0-9a-fA-F]{40}\"',s),'mainnet questRewards not set'"
  (cd web && printf 'mainnet' | vercel env add NETWORK production >/dev/null)
  # Vercel builds production from git (Root Directory = web); redeploy by pushing, never `vercel deploy` from web/.
  git add web/api/_networks.ts deployments/mainnet.json && git commit -m "Go live: QuestRewards on BSC mainnet" && git push origin main
  echo "Pushed. When the Vercel production build is Ready:"; echo "  curl -s https://agentic-quest.vercel.app/api/campaigns | head -c 300" ;;
*) sed -n 2,18p "$0"; exit 1 ;;
esac
