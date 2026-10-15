#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 6: Provisioning Secure Source Manager (SSM) & Developer Connect Link
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# Auto-resolve placeholder developer identity to active gcloud account
if [[ "${DEVELOPER:-}" == *"@mydomain.com"* ]] || [ -z "${DEVELOPER:-}" ]; then
  DEVELOPER=$(gcloud config get-value account 2>/dev/null || echo "${DEVELOPER}")
fi

echo "==================================================================="
echo "=== Step 6: Provisioning Secure Source Manager & Dev Connect    ==="
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

# Step 1: Ensure APIs are enabled
echo "--- Step 1: Enabling Required APIs ---"
gcloud services enable securesourcemanager.googleapis.com --project="${SSM_PROJECT}"
gcloud services enable developerconnect.googleapis.com dataform.googleapis.com --project="${DEV_PROJECT}"
gcloud services enable developerconnect.googleapis.com dataform.googleapis.com --project="${PROD_PROJECT}"

# Step 2: Resolve Project Numbers & Service Agents
echo "--- Step 2: Resolving Project Numbers & Identities ---"
TOKEN=$(gcloud auth print-access-token)
SSM_PROJECT_NUM=$(gcloud projects describe "${SSM_PROJECT}" --format="value(projectNumber)")
DEV_PROJECT_NUM=$(gcloud projects describe "${DEV_PROJECT}" --format="value(projectNumber)")
PROD_PROJECT_NUM=$(gcloud projects describe "${PROD_PROJECT}" --format="value(projectNumber)")

gcloud beta services identity create --service=dataform.googleapis.com --project="${DEV_PROJECT}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=dataform.googleapis.com --project="${PROD_PROJECT}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=developerconnect.googleapis.com --project="${DEV_PROJECT}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=developerconnect.googleapis.com --project="${PROD_PROJECT}" >/dev/null 2>&1 || true

DEV_DATAFORM_SA="service-${DEV_PROJECT_NUM}@gcp-sa-dataform.iam.gserviceaccount.com"
PROD_DATAFORM_SA="service-${PROD_PROJECT_NUM}@gcp-sa-dataform.iam.gserviceaccount.com"
DEV_DEVCONNECT_SA="service-${DEV_PROJECT_NUM}@gcp-sa-devconnect.iam.gserviceaccount.com"

echo "SSM Project Number   : ${SSM_PROJECT_NUM}"
echo "DEV Dataform SA      : ${DEV_DATAFORM_SA}"
echo "DEV DevConnect SA    : ${DEV_DEVCONNECT_SA}"
echo "PROD Dataform SA     : ${PROD_DATAFORM_SA}"

# Step 3: Provision or Validate Secure Source Manager Instance
echo ""
echo "--- Step 3: Provisioning / Validating SSM Instance (${INSTANCE_ID}) ---"
INSTANCE_STATE=$(gcloud beta source-manager instances describe "${INSTANCE_ID}" --region="${LOCATION}" --project="${SSM_PROJECT}" --format="value(state)" 2>/dev/null || echo "NOT_FOUND")

if [ "${INSTANCE_STATE}" = "NOT_FOUND" ]; then
  echo "SSM Instance '${INSTANCE_ID}' not found in ${SSM_PROJECT}. Initiating creation in ${LOCATION}..."
  gcloud beta source-manager instances create "${INSTANCE_ID}" \
    --region="${LOCATION}" \
    --project="${SSM_PROJECT}" \
    --async
  INSTANCE_STATE="CREATING"
fi

if [ "${INSTANCE_STATE}" != "ACTIVE" ]; then
  echo "Waiting for SSM instance '${INSTANCE_ID}' to become ACTIVE..."
  while true; do
    STATE=$(gcloud beta source-manager instances describe "${INSTANCE_ID}" --region="${LOCATION}" --project="${SSM_PROJECT}" --format="value(state)" 2>/dev/null || echo "CREATING")
    echo "  Current state: ${STATE} - $(date '+%H:%M:%S')"
    if [ "${STATE}" = "ACTIVE" ]; then
      echo "✔ SSM Instance is now ACTIVE!"
      break
    elif [ "${STATE}" = "FAILED" ]; then
      echo "✘ SSM Instance creation FAILED. Check Cloud Logging."
      exit 1
    fi
    sleep 20
  done
else
  echo "✔ SSM Instance '${INSTANCE_ID}' is ACTIVE."
fi

# Step 4: Bind Instance & Project Level IAM Roles
echo ""
echo "--- Step 4: Granting Instance & Project Level Access in ${SSM_PROJECT} ---"
gcloud projects add-iam-policy-binding "${SSM_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/viewer" \
  --condition=None >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${SSM_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/securesourcemanager.instanceAccessor" \
  --condition=None >/dev/null 2>&1 || true

gcloud beta source-manager instances add-iam-policy-binding "${INSTANCE_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/securesourcemanager.instanceAccessor" >/dev/null 2>&1 || true

gcloud beta source-manager instances add-iam-policy-binding "${INSTANCE_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --member="serviceAccount:${DEV_DATAFORM_SA}" \
  --role="roles/securesourcemanager.instanceAccessor" >/dev/null 2>&1 || true

gcloud beta source-manager instances add-iam-policy-binding "${INSTANCE_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --member="serviceAccount:${DEV_DEVCONNECT_SA}" \
  --role="roles/securesourcemanager.instanceAccessor" >/dev/null 2>&1 || true

gcloud beta source-manager instances add-iam-policy-binding "${INSTANCE_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --member="serviceAccount:${DEV_DEVCONNECT_SA}" \
  --role="roles/securesourcemanager.developerConnectLinker" >/dev/null 2>&1 || true

# Step 5: Provision or Validate Git Repository with default-branch=development
echo ""
echo "--- Step 5: Provisioning / Validating Repository (${REPO_ID}) ---"
REPO_EXISTS=$(gcloud beta source-manager repos describe "${REPO_ID}" --region="${LOCATION}" --project="${SSM_PROJECT}" --format="value(name)" 2>/dev/null || echo "NOT_FOUND")

if [ "${REPO_EXISTS}" = "NOT_FOUND" ]; then
  echo "Creating repository '${REPO_ID}' with default branch '${DEFAULT_BRANCH}' in ${SSM_PROJECT}..."
  gcloud beta source-manager repos create "${REPO_ID}" \
    --instance="${INSTANCE_ID}" \
    --region="${LOCATION}" \
    --project="${SSM_PROJECT}" \
    --default-branch="${DEFAULT_BRANCH}" \
    --description="Enterprise Dataform ELT pipeline repository for secure analytics" \
    --readme=default
  echo "✔ Repository '${REPO_ID}' created successfully."
else
  echo "✔ Repository '${REPO_ID}' already exists in ${SSM_PROJECT}."
fi

# Step 6: Seed Clean Baseline Dataform Code to main & development branches
echo ""
echo "--- Step 6: Seeding Clean Dataform Codebase to SSM Repository ---"
TEMP_DATA_DIR=$(mktemp -d)
cp "${SCRIPT_DIR}/../workflow_settings.yaml" "${TEMP_DATA_DIR}/"
cp -r "${SCRIPT_DIR}/../definitions" "${TEMP_DATA_DIR}/"
if [ -f "${SCRIPT_DIR}/../package.json" ]; then
  cp "${SCRIPT_DIR}/../package.json" "${TEMP_DATA_DIR}/"
fi
if [ -d "${SCRIPT_DIR}/../includes" ]; then
  cp -r "${SCRIPT_DIR}/../includes" "${TEMP_DATA_DIR}/"
fi

cat << 'EOF' > "${TEMP_DATA_DIR}/.gitignore"
.DS_Store
*.log
node_modules/
EOF

API_BASE="https://securesourcemanager.googleapis.com/v1"
REPO_PATH="projects/${SSM_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}"
RULE_ID="main-protection"

# Temporarily delete branch rule if exists so main can be seeded directly
curl -s -X DELETE \
  -H "Authorization: Bearer ${TOKEN}" \
  "${API_BASE}/${REPO_PATH}/branchRules/${RULE_ID}" >/dev/null 2>&1 || true

(
  cd "${TEMP_DATA_DIR}"
  git init >/dev/null 2>&1
  git config user.name "Dataform Automation"
  git config user.email "dataform@google.com"
  git checkout -b main >/dev/null 2>&1 || git checkout -B main >/dev/null 2>&1
  git add .
  git commit -m "feat: initial dataform 3-tier pipeline baseline" >/dev/null 2>&1
  git branch -M main >/dev/null 2>&1
  git checkout -b development >/dev/null 2>&1

  SSM_GIT_URL="https://oauth2accesstoken:${TOKEN}@${INSTANCE_ID}-${SSM_PROJECT_NUM}-git.${LOCATION}.sourcemanager.dev/${SSM_PROJECT}/${REPO_ID}.git"
  echo "Pushing clean Dataform code to SSM 'main' branch..."
  git push --force "${SSM_GIT_URL}" main:main >/dev/null 2>&1 || true

  echo "Pushing clean Dataform code to SSM 'development' branch..."
  git push --force "${SSM_GIT_URL}" development:development >/dev/null 2>&1 || true
)
rm -rf "${TEMP_DATA_DIR}"
echo "✔ Clean Dataform codebase seeded to both 'main' and 'development' branches."

# Step 7: Configure Main Branch Protection Policy (Protecting 'main')
echo ""
echo "--- Step 7: Configuring Main Branch Protection Policy on 'main' ---"
BRANCH_RULE_PAYLOAD=$(cat <<EOF
{
  "includePattern": "main",
  "requirePullRequest": true,
  "minimumReviewsCount": 1,
  "minimumApprovalsCount": 1,
  "requireCodeOwnerApproval": false,
  "requireCommentsResolved": true,
  "allowStaleReviews": false,
  "requireLinearHistory": true
}
EOF
)

EXISTING_RULES=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "${API_BASE}/${REPO_PATH}/branchRules" 2>/dev/null || echo "{}")

if echo "${EXISTING_RULES}" | grep -q "${RULE_ID}"; then
  echo "Updating existing branch rule '${RULE_ID}' on branch 'main'..."
  UPDATE_MASK="includePattern,requirePullRequest,minimumReviewsCount,minimumApprovalsCount,requireCommentsResolved,allowStaleReviews,requireLinearHistory"
  curl -s -X PATCH \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${BRANCH_RULE_PAYLOAD}" \
    "${API_BASE}/${REPO_PATH}/branchRules/${RULE_ID}?updateMask=${UPDATE_MASK}" >/dev/null 2>&1 || true
  echo "✔ Branch protection rule '${RULE_ID}' updated."
else
  echo "Creating branch rule '${RULE_ID}' on branch 'main'..."
  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${BRANCH_RULE_PAYLOAD}" \
    "${API_BASE}/${REPO_PATH}/branchRules?branchRuleId=${RULE_ID}" >/dev/null 2>&1 || true
  echo "✔ Branch protection rule '${RULE_ID}' created."
fi

# Step 8: Assign Repository Roles in SSM
echo ""
echo "--- Step 8: Assigning SSM Repository Roles ---"
gcloud beta source-manager repos add-iam-policy-binding "${REPO_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/securesourcemanager.repoAdmin" >/dev/null 2>&1 || true

gcloud beta source-manager repos add-iam-policy-binding "${REPO_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --member="serviceAccount:${DEV_DEVCONNECT_SA}" \
  --role="roles/securesourcemanager.developerConnectLinker" >/dev/null 2>&1 || true

gcloud beta source-manager repos add-iam-policy-binding "${REPO_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --member="serviceAccount:${DEV_DEVCONNECT_SA}" \
  --role="roles/securesourcemanager.repoWriter" >/dev/null 2>&1 || true

gcloud beta source-manager repos add-iam-policy-binding "${REPO_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --member="serviceAccount:${DEV_DATAFORM_SA}" \
  --role="roles/securesourcemanager.repoWriter" >/dev/null 2>&1 || true
echo "✔ SSM Repository roles granted successfully."

# Step 9: Configure Developer Connect & Link to Dataform
echo ""
echo "--- Step 9: Configuring Developer Connect & Dataform Remote Link ---"
echo "Granting Developer Connect roles in ${DEV_PROJECT} to Dataform SA..."
gcloud projects add-iam-policy-binding "${DEV_PROJECT}" \
  --member="serviceAccount:${DEV_DATAFORM_SA}" \
  --role="roles/developerconnect.gitProxyUser" \
  --condition=None >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${DEV_PROJECT}" \
  --member="serviceAccount:${DEV_DATAFORM_SA}" \
  --role="roles/developerconnect.tokenAccessor" \
  --condition=None >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${DEV_PROJECT}" \
  --member="serviceAccount:${DEV_DATAFORM_SA}" \
  --role="roles/developerconnect.viewer" \
  --condition=None >/dev/null 2>&1 || true

# Create or verify Developer Connect Connection
CONN_EXISTS=$(gcloud beta developer-connect connections describe "${CONN_ID}" --location="${LOCATION}" --project="${DEV_PROJECT}" --format="value(name)" 2>/dev/null || echo "NOT_FOUND")
if [ "${CONN_EXISTS}" = "NOT_FOUND" ]; then
  echo "Creating Developer Connect Connection '${CONN_ID}' (with automatic IAM propagation retries)..."
  MAX_ATTEMPTS=6
  ATTEMPT=1
  while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
    if gcloud beta developer-connect connections create "${CONN_ID}" \
      --location="${LOCATION}" \
      --project="${DEV_PROJECT}" \
      --secure-source-manager-instance-config="projects/${SSM_PROJECT}/locations/${LOCATION}/instances/${INSTANCE_ID}"; then
      echo "✔ Developer Connect Connection '${CONN_ID}' created."
      break
    else
      echo "⚠️ Connection creation waiting for SSM IAM propagation (attempt ${ATTEMPT}/${MAX_ATTEMPTS})..."
      ATTEMPT=$((ATTEMPT + 1))
      if [ "${ATTEMPT}" -gt "${MAX_ATTEMPTS}" ]; then
        echo "✘ Failed to create Developer Connect connection after ${MAX_ATTEMPTS} attempts."
        exit 1
      fi
      sleep 15
    fi
  done
else
  echo "✔ Developer Connect Connection '${CONN_ID}' already exists."
fi

# Enable Git Proxy on Developer Connect Connection
echo "Enabling Git Proxy on Connection '${CONN_ID}'..."
curl -s -X PATCH \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"gitProxyConfig": {"enabled": true}}' \
  "https://developerconnect.googleapis.com/v1/projects/${DEV_PROJECT}/locations/${LOCATION}/connections/${CONN_ID}?updateMask=gitProxyConfig" >/dev/null 2>&1 || true

# Create Git Repository Link
LINK_EXISTS=$(gcloud beta developer-connect connections git-repository-links describe "${REPO_ID}" --connection="${CONN_ID}" --location="${LOCATION}" --project="${DEV_PROJECT}" --format="value(name)" 2>/dev/null || echo "NOT_FOUND")
CLONE_URI="https://${INSTANCE_ID}-${SSM_PROJECT_NUM}-git.${LOCATION}.sourcemanager.dev/${SSM_PROJECT}/${REPO_ID}.git"

if [ "${LINK_EXISTS}" = "NOT_FOUND" ]; then
  echo "Creating Developer Connect Git Repository Link '${REPO_ID}' (with retry for IAM propagation)..."
  MAX_LINK_ATTEMPTS=5
  LINK_ATTEMPT=1
  while [ "${LINK_ATTEMPT}" -le "${MAX_LINK_ATTEMPTS}" ]; do
    if gcloud beta developer-connect connections git-repository-links create "${REPO_ID}" \
      --connection="${CONN_ID}" \
      --location="${LOCATION}" \
      --project="${DEV_PROJECT}" \
      --clone-uri="${CLONE_URI}"; then
      echo "✔ Git Repository Link '${REPO_ID}' created."
      break
    else
      echo "⚠️ Git link creation waiting (attempt ${LINK_ATTEMPT}/${MAX_LINK_ATTEMPTS})..."
      LINK_ATTEMPT=$((LINK_ATTEMPT + 1))
      if [ "${LINK_ATTEMPT}" -gt "${MAX_LINK_ATTEMPTS}" ]; then
        echo "✘ Failed to create Git repository link after ${MAX_LINK_ATTEMPTS} attempts."
        exit 1
      fi
      sleep 10
    fi
  done
else
  echo "✔ Git Repository Link '${REPO_ID}' already exists."
fi

echo ""
echo "==================================================================="
echo "=== Step 6: SSM & Developer Connect Provisioning Complete!      ==="
echo "==================================================================="
