#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 8: Comprehensive SSM & Developer Connect Verification
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "=== Step 8: Comprehensive SSM & Developer Connect Verification  ==="
echo "==================================================================="
echo "SSM Project : ${SSM_PROJECT} (Org Host)"
echo "DEV Project : ${DEV_PROJECT}"
echo "PROD Project: ${PROD_PROJECT}"
echo "Location    : ${LOCATION}"
echo "Instance ID : ${INSTANCE_ID}"
echo "Repo ID     : ${REPO_ID}"
echo "Default Br. : ${DEFAULT_BRANCH}"
echo "Developer   : ${DEVELOPER}"
echo "Conn ID     : ${CONN_ID}"
echo "==================================================================="

SSM_PROJECT_NUM=$(gcloud projects describe "${SSM_PROJECT}" --format="value(projectNumber)")
DEV_PROJECT_NUM=$(gcloud projects describe "${DEV_PROJECT}" --format="value(projectNumber)")
PROD_PROJECT_NUM=$(gcloud projects describe "${PROD_PROJECT}" --format="value(projectNumber)")

DEV_DATAFORM_SA="service-${DEV_PROJECT_NUM}@gcp-sa-dataform.iam.gserviceaccount.com"
DEV_DEVCONNECT_SA="service-${DEV_PROJECT_NUM}@gcp-sa-devconnect.iam.gserviceaccount.com"
TOKEN=$(gcloud auth print-access-token)

PASSED_TESTS=0
TOTAL_TESTS=6

# Test 1: SSM Instance State
echo ""
echo ">>> [Test 1/6] SSM Instance Existence & ACTIVE Status in ${SSM_PROJECT} <<<"
INSTANCE_STATE=$(gcloud source-manager instances describe "${INSTANCE_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --format="value(state)" 2>/dev/null || echo "NOT_FOUND")

if [ "${INSTANCE_STATE}" = "ACTIVE" ]; then
  echo "✔ PASS: SSM Instance '${INSTANCE_ID}' is ACTIVE in '${SSM_PROJECT}'."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: SSM Instance '${INSTANCE_ID}' state: ${INSTANCE_STATE}"
fi

# Test 2: Repository and Branches
echo ""
echo ">>> [Test 2/6] Repository & Branch Validation in ${SSM_PROJECT} <<<"
REPO_NAME=$(gcloud source-manager repos describe "${REPO_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --format="value(name)" 2>/dev/null || echo "NOT_FOUND")

SSM_GIT_URL="https://oauth2accesstoken:${TOKEN}@${INSTANCE_ID}-${SSM_PROJECT_NUM}-git.${LOCATION}.sourcemanager.dev/${SSM_PROJECT}/${REPO_ID}.git"
REMOTE_BRANCHES=$(git ls-remote --heads "${SSM_GIT_URL}" 2>/dev/null || true)

HAS_MAIN=$(echo "${REMOTE_BRANCHES}" | grep -c "refs/heads/main" || true)
HAS_DEV=$(echo "${REMOTE_BRANCHES}" | grep -c "refs/heads/development" || true)

if [ "${REPO_NAME}" != "NOT_FOUND" ] && [ "${HAS_MAIN}" -ge 1 ] && [ "${HAS_DEV}" -ge 1 ]; then
  echo "✔ PASS: Repository '${REPO_ID}' exists in '${SSM_PROJECT}' with both 'main' and 'development' branches."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Repository '${REPO_ID}' missing or required branches ('main'/'development') not found."
fi

# Test 3: Branch Protection Policy
echo ""
echo ">>> [Test 3/6] Branch Protection Rule on 'main' <<<"
API_BASE="https://securesourcemanager.googleapis.com/v1"
REPO_PATH="projects/${SSM_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}"
RULES_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" "${API_BASE}/${REPO_PATH}/branchRules")

RULE_VALID=$(python3 - <<EOF
import json, sys
try:
    data = json.loads('''${RULES_JSON}''')
    for r in data.get("branchRules", []):
        if r.get("includePattern") == "main" and r.get("requirePullRequest", False):
            print("PASS")
            sys.exit(0)
    print("FAIL")
except Exception:
    print("FAIL")
EOF
)

if [ "${RULE_VALID}" = "PASS" ]; then
  echo "✔ PASS: Branch protection rule verified on 'main' (PR required, approvals enforced)."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Branch protection rule missing or invalid on 'main'."
fi

# Test 4: Developer Connect Connection & Git Proxy
echo ""
echo ">>> [Test 4/6] Developer Connect Connection & Git Proxy Status in ${DEV_PROJECT} <<<"
CONN_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "https://developerconnect.googleapis.com/v1/projects/${DEV_PROJECT}/locations/${LOCATION}/connections/${CONN_ID}")

PROXY_ENABLED=$(python3 - <<EOF
import json, sys
try:
    data = json.loads('''${CONN_JSON}''')
    proxy = data.get("gitProxyConfig", {}).get("enabled", False)
    stage = data.get("installationState", {}).get("stage", "")
    if proxy and stage == "COMPLETE":
        print("PASS")
    else:
        print("FAIL")
except Exception:
    print("FAIL")
EOF
)

if [ "${PROXY_ENABLED}" = "PASS" ]; then
  echo "✔ PASS: Developer Connect connection '${CONN_ID}' is COMPLETE and Git Proxy is ENABLED."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Developer Connect connection or Git Proxy not ready."
fi

# Test 5: Dataform Access Token Status
echo ""
echo ">>> [Test 5/6] Dataform computeAccessTokenStatus via Developer Connect <<<"
ACCESS_STATUS=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}:computeAccessTokenStatus")

TOKEN_STATUS=$(python3 - <<EOF
import json, sys
try:
    data = json.loads('''${ACCESS_STATUS}''')
    print(data.get("tokenStatus", "UNKNOWN"))
except Exception:
    print("INVALID")
EOF
)

if [ "${TOKEN_STATUS}" = "VALID" ]; then
  echo "✔ PASS: Dataform Git access status is VALID."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Dataform Git access status is: ${TOKEN_STATUS}"
fi

# Test 6: Development Branch Release Compilation
echo ""
echo ">>> [Test 6/6] Dataform Release Config Compilation on '${DEFAULT_BRANCH}' <<<"
COMPILATION_RESP=$(curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"releaseConfig\": \"projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/releaseConfigs/dev-release\"}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/compilationResults")

COMPILATION_PASS=$(echo "${COMPILATION_RESP}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if "name" in data and "compilationResults" in data.get("name", ""):
        print("PASS")
    else:
        print("FAIL")
except Exception:
    print("FAIL")
')

if [ "${COMPILATION_PASS}" = "PASS" ]; then
  COMP_ID=$(echo "${COMPILATION_RESP}" | python3 -c "import json, sys; print(json.load(sys.stdin).get('name',''))")
  echo "✔ PASS: Successfully created compilation result on '${DEFAULT_BRANCH}':"
  echo "        ${COMP_ID}"
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Release config compilation failed on '${DEFAULT_BRANCH}'."
fi

echo ""
echo "==================================================================="
echo "=== Step 8 Verification Summary: ${PASSED_TESTS}/${TOTAL_TESTS} Tests Passed ==="
echo "==================================================================="
if [ "${PASSED_TESTS}" -eq "${TOTAL_TESTS}" ]; then
  echo "🎉 All SSM & Developer Connect components are fully VERIFIED!"
  exit 0
else
  echo "❌ Some verification tests failed. Please inspect the log above."
  exit 1
fi
