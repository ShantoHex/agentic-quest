#!/usr/bin/env bash
# Agentic Quest — mainnet launch helper (BNB Smart Chain, chainId 56).
# NOTHING runs without CONFIRM=yes: every step sends real mainnet transactions from the deployer (owner) wallet.
#
#   CONFIRM=yes scripts/launch-mainnet.sh deploy                       # deploy + Sourcify verify + setSigner(mainnet signer)
#   CONFIRM=yes scripts/launch-mainnet.sh campaign fcfs 0.10 50 <xPostId> "<title>" <budgetUSDT> [endUnix]
#   CONFIRM=yes scripts/launch-mainnet.sh campaign random 0 100 <xPostId> "<title>" <budgetUSDT> [endUnix]
#        (exact approve of <budget> + createQuest: creates AND funds; budget >= 1 (contract min, no contract max); this owner script limits each tranche to MAX_TRANCHE)
#   CONFIRM=yes scripts/launch-mainnet.sh fund <campaignId> <usdt>     # one small tranche (<= MAX_TRANCHE, default 25)
#   CONFIRM=yes scripts/launch-mainnet.sh golive                       # NETWORK=mainnet on Vercel + redeploy
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

if [ "${CONFIRM:-}" != "yes" ]; then sed -n 2,13p "$0"; echo "Refusing: set CONFIRM=yes (real mainnet transactions)."; exit 1; fi
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
  need_bnb 400000000000000   # 0.0004 BNB (deploy + setSigner ~3.1M gas at 0.1 gwei = ~0.00031)
  forge build >/dev/null
  ADDR=$(forge create src/QuestRewards.sol:QuestRewards --rpc-url "$RPC" --private-key "$PK" "${GAS[@]}" --broadcast --json \
        --constructor-args "$REGISTRY" "$USDT" "$OWNER" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
  echo "QuestRewards: $ADDR"
  forge verify-contract "$ADDR" src/QuestRewards.sol:QuestRewards --chain 56 --verifier sourcify \
        --constructor-args "$(cast abi-encode 'c(address,address,address)' "$REGISTRY" "$USDT" "$OWNER")" || echo "verify: retry later"
  cast send "$ADDR" "setSigner(address)" "$SIGNER" --rpc-url "$RPC" --private-key "$PK" "${GAS[@]}" >/dev/null
  [ "$(cast call "$ADDR" 'signer()(address)' --rpc-url "$RPC")" = "$SIGNER" ] || { echo "signer mismatch"; exit 1; }
  printf '{"chainId":56,"QuestRewards":"%s","owner":"%s","signer":"%s","agentIdRegistry":"%s","usdt":"%s"}\n' \
    "$ADDR" "$OWNER" "$SIGNER" "$REGISTRY" "$USDT" > "$OUT"
  sed -i "/key: \"mainnet\"/,/mockRegistry/ s#questRewards: \"[^\"]*\"#questRewards: \"$ADDR\"#" web/api/_networks.ts
  echo "Wrote $OUT and web/api/_networks.ts. Next: campaign, fund, golive." ;;
campaign)
  MODE=${2:?fcfs|random}; AMT=${3:?amount}; SLOTS=${4:?slots}; POST=${5:?xPostId}; TITLE=${6:?title}; BUDGET=${7:?budgetUSDT}; END=${8:-0}
  python3 -c "import sys; sys.exit(0 if float('$BUDGET') <= float('${MAX_TRANCHE:-25}') else 1)" \
    || { echo "Budget > MAX_TRANCHE (${MAX_TRANCHE:-25} USDT); start small and top up with fund"; exit 1; }
  need_bnb 50000000000000
  if [ "$MODE" = fcfs ]; then M=1; A=$(cast to-wei "$AMT"); elif [ "$MODE" = random ]; then M=0; A=0; else echo "mode?"; exit 1; fi
  B=$(cast to-wei "$BUDGET")
  cast send "$USDT" "approve(address,uint256)" "$(qr)" "$B" --rpc-url "$RPC" --private-key "$PK" "${GAS[@]}" >/dev/null
  cast send "$(qr)" "createQuest(uint8,uint256,uint32,uint64,string,string,uint256)" "$M" "$A" "$SLOTS" "$END" "$POST" "$TITLE" "$B" \
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
  (cd web && printf 'mainnet' | vercel env add NETWORK production >/dev/null && vercel deploy --prod --yes >/dev/null)
  curl -s https://agentic-quest.vercel.app/api/campaigns | head -c 300; echo ;;
*) sed -n 2,13p "$0"; exit 1 ;;
esac
