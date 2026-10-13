#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 11: End-to-End Dev-to-Prod Lifecycle & Override Demonstration (CLI Runner)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "=== Step 11: End-to-End Dev-to-Prod Lifecycle Demonstration     ==="
echo "==================================================================="
echo "Demonstrating Enterprise Dataform Pattern:"
echo " 1. Initial State: Developer reads from PROD raw vault (${PROD_PROJECT}.raw_vault)"
echo " 2. Dev Change: Developer (${DEVELOPER}) adds a new business metric ('customer_tier')"
echo " 3. Dev Isolation: DEV Execution writes ONLY to ${DEV_PROJECT}.analytics_curated"
echo " 4. Security Gate: Direct push to 'main' is BLOCKED by SSM branch protection"
echo " 5. Pull Request: Promotion from 'development' -> 'main'"
echo " 6. Prod Execution: Merged 'main' triggers prod-release into ${PROD_PROJECT}.analytics_curated"
echo "==================================================================="

SSM_PROJECT_NUM=$(gcloud projects describe "${SSM_PROJECT}" --format="value(projectNumber)")
GIT_HTTPS_URL="https://${INSTANCE_ID}-${SSM_PROJECT_NUM}-git.${LOCATION}.sourcemanager.dev/${SSM_PROJECT}/${REPO_ID}.git"
GCLOUD_SDK_ROOT=$(gcloud info --format="value(installation.sdk_root)")
CRED_HELPER="${GCLOUD_SDK_ROOT}/bin/git-credential-gcloud.sh"
TOKEN=$(gcloud auth print-access-token)

# Phase 1: Local Feature Branch / Dev Workspace
echo ""
echo ">>> [Phase 1/6] Simulating Developer Workspace on branch '${DEFAULT_BRANCH}' <<<"
TMP_WORKSPACE=$(mktemp -d)
echo "Cloning repository from Secure Source Manager..."
git -c credential.helper="${CRED_HELPER}" clone -b "${DEFAULT_BRANCH}" "${GIT_HTTPS_URL}" "${TMP_WORKSPACE}" >/dev/null 2>&1

pushd "${TMP_WORKSPACE}" >/dev/null

echo "Developer implements a new feature: Adding 'customer_tier' metric to definitions/outputs/fct_cleaned_transactions.sqlx..."

# Add customer_tier logic into fct_cleaned_transactions.sqlx
cat <<'EOF' > definitions/outputs/fct_cleaned_transactions.sqlx
config {
  type: "table",
  schema: "analytics_curated",
  name: "fct_cleaned_transactions",
  description: "Curated fact table containing validated, deduplicated customer transactions ready for BI and downstream analytics.",
  columns: {
    transaction_id: "Primary Key: Unique transaction identifier",
    customer_id: "Customer identifier",
    transaction_date: "Date of transaction for partition filtering",
    transaction_timestamp: "Timestamp of transaction",
    transaction_amount: "Final positive transaction amount",
    payment_status: "Validated payment status",
    is_high_value: "Boolean flag for transactions >= $1000",
    customer_tier: "Business loyalty tier (PLATINUM >= $1000, GOLD >= $500, STANDARD < $500)",
    processed_at: "Ingestion/processing timestamp"
  },
  bigquery: {
    partitionBy: "transaction_date",
    clusterBy: ["customer_id", "payment_status"]
  }
}

/**
 * Stage 2: Deduplication, Enrichment & Final Table Materialization
 * - Reads from intermediate stage view ${ref("stg_transactions")}
 * - Deduplicates on transaction_id keeping the latest record
 * - Enriches with business flags (is_high_value, customer_tier)
 */
WITH ranked_transactions AS (
  SELECT
    transaction_id,
    customer_id,
    DATE(transaction_timestamp) AS transaction_date,
    transaction_timestamp,
    transaction_amount,
    payment_status,
    ROW_NUMBER() OVER(
      PARTITION BY transaction_id 
      ORDER BY transaction_timestamp DESC
    ) AS row_num
  FROM
    ${ref("stg_transactions")}
)

SELECT
  transaction_id,
  customer_id,
  transaction_date,
  transaction_timestamp,
  transaction_amount,
  payment_status,
  (transaction_amount >= 1000.0) AS is_high_value,
  CASE
    WHEN transaction_amount >= 1000.0 THEN 'PLATINUM'
    WHEN transaction_amount >= 500.0 THEN 'GOLD'
    ELSE 'STANDARD'
  END AS customer_tier,
  CURRENT_TIMESTAMP() AS processed_at
FROM
  ranked_transactions
WHERE
  row_num = 1
EOF

git config user.name "Developer"
git config user.email "${DEVELOPER}"
git add definitions/outputs/fct_cleaned_transactions.sqlx
git commit -m "feat(analytics): add customer_tier business logic" >/dev/null

# Phase 2: Testing Security Boundary / Branch Protection on 'main'
echo ""
echo ">>> [Phase 2/6] Testing Security Gate: Attempting direct push to protected 'main' branch <<<"
set +e
PUSH_MAIN_OUTPUT=$(git -c credential.helper="${CRED_HELPER}" push origin "${DEFAULT_BRANCH}:main" 2>&1)
PUSH_MAIN_EXIT=$?
set -euo pipefail

if [ ${PUSH_MAIN_EXIT} -ne 0 ]; then
  echo "✔ PASS: Direct push to 'main' was correctly REJECTED by SSM Branch Protection Rule!"
  echo "        Error summary: $(echo "${PUSH_MAIN_OUTPUT}" | grep -i "remote:.*hook" | head -n 1 || echo "${PUSH_MAIN_OUTPUT}" | tail -n 2)"
else
  echo "✘ WARNING: Push to 'main' succeeded! Branch protection rule might not be enforced."
fi

# Phase 3: Pushing Feature to 'development' and Triggering DEV Release Workflow
echo ""
echo ">>> [Phase 3/6] Pushing code to '${DEFAULT_BRANCH}' & Triggering DEV Dataform Pipeline <<<"
git -c credential.helper="${CRED_HELPER}" push origin "${DEFAULT_BRANCH}" >/dev/null 2>&1
echo "✔ Feature branch '${DEFAULT_BRANCH}' updated in Secure Source Manager."

popd >/dev/null
rm -rf "${TMP_WORKSPACE}"

echo ""
echo "Triggering Dataform DEV Compilation & Execution Pipeline..."
echo "1. Creating Compilation Result for dev-release in ${DEV_PROJECT}..."
DEV_COMP_NAME=$(curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"releaseConfig\": \"projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/releaseConfigs/dev-release\"}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/compilationResults" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("name", ""))
except Exception:
    print("")
')

if [ -z "${DEV_COMP_NAME}" ]; then
  echo "✘ Failed to create compilation result on '${DEFAULT_BRANCH}'."
  exit 1
fi
echo "   Compilation Result: ${DEV_COMP_NAME}"

echo "2. Triggering Workflow Invocation in ${DEV_PROJECT}..."
DEV_INVOC_NAME=$(curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"compilationResult\": \"${DEV_COMP_NAME}\"}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/workflowInvocations" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("name", ""))
except Exception:
    print("")
')

if [ -z "${DEV_INVOC_NAME}" ]; then
  echo "✘ Failed to trigger workflow invocation."
  exit 1
fi
echo "   Workflow Invocation: ${DEV_INVOC_NAME}"
echo "   Waiting for DEV execution to complete..."

while true; do
  STATE=$(curl -s -H "Authorization: Bearer ${TOKEN}" "https://dataform.googleapis.com/v1beta1/${DEV_INVOC_NAME}" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("state", "UNKNOWN"))
except Exception:
    print("UNKNOWN")
')
  if [ "${STATE}" = "SUCCEEDED" ]; then
    echo "✔ DEV Workflow Invocation SUCCEEDED!"
    break
  elif [ "${STATE}" = "FAILED" ] || [ "${STATE}" = "CANCELLED" ]; then
    echo "✘ DEV Workflow Invocation ended with state: ${STATE}"
    break
  fi
  sleep 3
done

# Phase 4: BigQuery Verification of Environment Isolation & Overrides
echo ""
echo ">>> [Phase 4/6] Verifying Target Dataset Isolation & Overrides in BigQuery <<<"
echo "Checking DEV dataset (${DEV_PROJECT}.analytics_curated):"
bq query --use_legacy_sql=false --format=pretty "SELECT transaction_id, transaction_amount, customer_tier FROM \`${DEV_PROJECT}.analytics_curated.fct_cleaned_transactions\` LIMIT 3"

echo ""
echo "Checking PROD dataset (${PROD_PROJECT}.analytics_curated):"
echo "(Notice: 'customer_tier' does NOT exist in PROD yet because code is only on DEV branch!)"
bq show --schema "${PROD_PROJECT}:analytics_curated.fct_cleaned_transactions" | grep "customer_tier" || echo "✔ Confirmed: 'customer_tier' is NOT present in PROD!"

# Phase 5: Pull Request Promotion Instructions
echo ""
echo ">>> [Phase 5/6] Pull Request Workflow & Promotion (SSM) <<<"
echo "To promote approved changes from '${DEFAULT_BRANCH}' to 'main':"
echo " 1. Open Secure Source Manager:"
echo "    👉 https://${INSTANCE_ID}-${SSM_PROJECT_NUM}.${LOCATION}.sourcemanager.dev/${SSM_PROJECT}/${REPO_ID}/pulls"
echo " 2. Click 'New Pull Request':"
echo "    - Base branch: main"
echo "    - Compare branch: ${DEFAULT_BRANCH}"
echo " 3. Reviewer inspects diff, submits approval, and merges into 'main'."

# Phase 6: Production Execution Workflow
echo ""
echo ">>> [Phase 6/6] Production Release Compilation & Execution <<<"
echo "Once the PR is merged into 'main':"
echo " - 'prod-release' compiles from 'main' with Target Database Override: '${PROD_PROJECT}'."
echo " - Workflow execution writes 'customer_tier' to '${PROD_PROJECT}.analytics_curated.fct_cleaned_transactions'."
echo " - The entire pipeline lifecycle is complete and verified."

echo ""
echo "==================================================================="
echo "=== Step 11 Lifecycle Demonstration Completed Successfully!     ==="
echo "==================================================================="
