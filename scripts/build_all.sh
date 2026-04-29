#!/usr/bin/env bash
set -euo pipefail

for agent in kyc-agent fraud-agent policy-rag-agent omni-agent; do
  echo "Building $agent"
  (cd "$agent" && bal build)
done
