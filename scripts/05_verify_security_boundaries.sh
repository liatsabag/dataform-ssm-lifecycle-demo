#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 5: Automated Security Boundary & Permission Verification
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "=== Step 5: Automated Security Boundary & IAM Verification      ==="
echo "==================================================================="
echo "DEV Project : ${DEV_PROJECT}"
echo "PROD Project: ${PROD_PROJECT}"
echo "Developer   : ${DEVELOPER}"
echo "Location    : ${LOCATION}"
echo "==================================================================="

DEV_PROJECT_NUM=$(gcloud projects describe "${DEV_PROJECT}" --format="value(projectNumber)")
DEV_DATAFORM_SA="service-${DEV_PROJECT_NUM}@gcp-sa-dataform.iam.gserviceaccount.com"

PASSED_TESTS=0
TOTAL_TESTS=5

# Test 1: Cross-Project Source Read (DEV querying PROD raw_vault)
echo ""
echo ">>> [Test 1/5] Positive Test: Cross-Project Query Execution (DEV Job reading PROD raw_vault) <<<"
if bq query \
  --project_id="${DEV_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  "SELECT count(*) AS raw_count FROM \`${PROD_PROJECT}.raw_vault.raw_transactions\`" >/dev/null 2>&1; then
  echo "✔ PASS: Cross-project query successfully executed from DEV against PROD raw_vault."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Could not execute cross-project query from DEV against PROD raw_vault."
fi

# Test 2: DEV Dataset Accessibility
echo ""
echo ">>> [Test 2/5] Positive Test: DEV Dataset Accessibility in ${DEV_PROJECT}.analytics_curated <<<"
if bq show "${DEV_PROJECT}:analytics_curated" >/dev/null 2>&1; then
  echo "✔ PASS: Successfully accessed DEV analytics_curated dataset."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Could not access DEV analytics_curated dataset."
fi

# Test 3: Dataform Cross-Project Compilation
echo ""
echo ">>> [Test 3/5] Positive Test: Dataform Pipeline Compilation & Cross-Project Resolution <<<"
cd "$(dirname "$0")/.."
if npx -y @dataform/cli compile . >/dev/null 2>&1; then
  echo "✔ PASS: Dataform compiled successfully with cross-project source references."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Dataform compilation failed."
fi

# Test 4: Security Policy Check on PROD raw_vault (Strict Read-Only Enforcement)
echo ""
echo ">>> [Test 4/5] Security Check: Verify PROD raw_vault ACL is strictly Read-Only for Developer & DEV SA <<<"
ACL_RAW_VAULT=$(bq show --format=prettyjson "${PROD_PROJECT}:raw_vault")

python3 - <<EOF
import json, sys

data = json.loads('''${ACL_RAW_VAULT}''')
access = data.get("access", [])

developer = "${DEVELOPER}"
dev_sa = "${DEV_DATAFORM_SA}"

dev_roles = [e.get("role") for e in access if e.get("userByEmail") == developer or e.get("iamMember") == f"user:{developer}"]
dev_sa_roles = [e.get("role") for e in access if e.get("userByEmail") == dev_sa or e.get("iamMember") == f"serviceAccount:{dev_sa}"]

# Developer must only have dataViewer / READER
for r in dev_roles:
    if "Editor" in r or "Owner" in r or "WRITER" in r or "OWNER" in r:
        print(f"FAIL: Developer has elevated write role on PROD raw_vault: {r}", file=sys.stderr)
        sys.exit(1)

# DEV SA must only have dataViewer / READER on PROD raw_vault
for r in dev_sa_roles:
    if "Editor" in r or "Owner" in r or "WRITER" in r or "OWNER" in r:
        print(f"FAIL: DEV SA has elevated write role on PROD raw_vault: {r}", file=sys.stderr)
        sys.exit(1)

if "roles/bigquery.dataViewer" in dev_roles and "roles/bigquery.dataViewer" in dev_sa_roles:
    print("SUCCESS: Developer and DEV SA are strictly constrained to roles/bigquery.dataViewer on PROD raw_vault.")
else:
    print(f"Roles found - Developer: {dev_roles}, DEV SA: {dev_sa_roles}")

EOF
if [ $? -eq 0 ]; then
  echo "✔ PASS: Security boundary confirmed: strictly read-only on PROD raw_vault."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Security boundary violation detected on PROD raw_vault ACL."
fi

# Test 5: Negative Security Check on PROD Curated Datasets
echo ""
echo ">>> [Test 5/5] Negative Security Check: Verify Developer & DEV SA have NO unauthorized write access to PROD output datasets <<<"
ACL_PROD_CURATED=$(bq show --format=prettyjson "${PROD_PROJECT}:analytics_curated")

python3 - <<EOF
import json, sys

data = json.loads('''${ACL_PROD_CURATED}''')
access = data.get("access", [])

developer = "${DEVELOPER}"
dev_sa = "${DEV_DATAFORM_SA}"

# Ensure neither Developer nor DEV SA has write access on PROD analytics_curated
for e in access:
    m = e.get("userByEmail") or e.get("iamMember") or ""
    if developer in m or dev_sa in m:
        r = e.get("role", "")
        if "Editor" in r or "Owner" in r or "WRITER" in r or "OWNER" in r:
            print(f"FAIL: Unauthorized write access on PROD curated dataset for {m} with role {r}", file=sys.stderr)
            sys.exit(1)

print("SUCCESS: Confirmed zero unauthorized write access for Developer and DEV SA on PROD curated dataset.")
EOF
if [ $? -eq 0 ]; then
  echo "✔ PASS: Negative security test passed: PROD output datasets are protected against DEV contamination."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Negative security test failed: unauthorized write binding found on PROD output dataset."
fi

echo ""
echo "==================================================================="
echo "=== Step 5 Verification Summary: ${PASSED_TESTS}/${TOTAL_TESTS} Tests Passed ==="
echo "==================================================================="
if [ "${PASSED_TESTS}" -eq "${TOTAL_TESTS}" ]; then
  echo "🎉 All least-privilege security boundaries and cross-project policies are VERIFIED!"
  exit 0
else
  echo "❌ Some verification tests failed. Please review output above."
  exit 1
fi
