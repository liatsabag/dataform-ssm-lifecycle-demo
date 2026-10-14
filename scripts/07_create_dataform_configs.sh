#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 7: Creating Dataform Repository, Workspaces, Release & Workflow Configs
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "=== Step 7: Creating Dataform Repository & Release Configs       ==="
echo "==================================================================="
echo "DEV Project        : ${DEV_PROJECT}"
echo "PROD Project       : ${PROD_PROJECT}"
echo "SSM Project        : ${SSM_PROJECT}"
echo "Location           : ${LOCATION}"
echo "Repository ID      : ${REPO_ID}"
echo "Default Branch     : ${DEFAULT_BRANCH}"
echo "Developer Workspace: ${DEVELOPER_WORKSPACE}"
echo "==================================================================="

TOKEN=$(gcloud auth print-access-token)
SSM_PROJECT_NUM=$(gcloud projects describe "${SSM_PROJECT}" --format="value(projectNumber)")
CLONE_URI="https://${INSTANCE_ID}-${SSM_PROJECT_NUM}-git.${LOCATION}.sourcemanager.dev/${SSM_PROJECT}/${REPO_ID}.git"
GIT_REPO_LINK="projects/${DEV_PROJECT}/locations/${LOCATION}/connections/${CONN_ID}/gitRepositoryLinks/${REPO_ID}"
EXECUTOR_SA="dataform-executor@${DEV_PROJECT}.iam.gserviceaccount.com"

# Step 1: Create Dataform Repository (if it does not exist)
echo ""
echo "--- Step 1: Provisioning / Linking Dataform Repository ---"
REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}")

DF_PAYLOAD=$(cat <<EOF
{
  "gitRemoteSettings": {
    "url": "${CLONE_URI}",
    "defaultBranch": "${DEFAULT_BRANCH}",
    "gitRepositoryLink": "${GIT_REPO_LINK}"
  },
  "workspaceCompilationOverrides": {
    "defaultDatabase": "${DEV_PROJECT}",
    "schemaSuffix": "\${workspaceName}"
  }
}
EOF
)

if [ "${REPO_CHECK}" = "404" ]; then
  echo "Creating Dataform repository '${REPO_ID}' in ${DEV_PROJECT}..."
  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${DF_PAYLOAD}" \
    "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories?repositoryId=${REPO_ID}" >/dev/null
  echo "✔ Dataform repository '${REPO_ID}' created."
else
  echo "Updating Dataform repository remote settings & workspace compilation overrides..."
  curl -s -X PATCH \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${DF_PAYLOAD}" \
    "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}?updateMask=gitRemoteSettings,workspaceCompilationOverrides" >/dev/null
  echo "✔ Dataform repository '${REPO_ID}' settings updated."
fi

# Step 2: Create Developer Workspace
echo ""
echo "--- Step 2: Provisioning Developer Workspace (${DEVELOPER_WORKSPACE}) ---"
WS_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/workspaces/${DEVELOPER_WORKSPACE}")

if [ "${WS_CHECK}" = "404" ]; then
  echo "Creating workspace '${DEVELOPER_WORKSPACE}'..."
  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/workspaces?workspaceId=${DEVELOPER_WORKSPACE}" >/dev/null
  echo "✔ Developer workspace '${DEVELOPER_WORKSPACE}' created."
else
  echo "✔ Developer workspace '${DEVELOPER_WORKSPACE}' already exists."
fi

# Step 3: Create Release Configurations (dev-release & prod-release)
echo ""
echo "--- Step 3: Creating Release Configurations ---"

# dev-release
DEV_REL_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/releaseConfigs/dev-release")

DEV_REL_PAYLOAD=$(cat <<EOF
{
  "gitCommitish": "development",
  "codeCompilationConfig": {
    "defaultDatabase": "${DEV_PROJECT}"
  },
  "cronSchedule": "0 */4 * * *"
}
EOF
)

if [ "${DEV_REL_CHECK}" = "404" ]; then
  echo "Creating dev-release configuration (targeting ${DEV_PROJECT})..."
  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${DEV_REL_PAYLOAD}" \
    "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/releaseConfigs?releaseConfigId=dev-release" >/dev/null
  echo "✔ dev-release created."
else
  echo "✔ dev-release already exists."
fi

# prod-release
PROD_REL_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/releaseConfigs/prod-release")

PROD_REL_PAYLOAD=$(cat <<EOF
{
  "gitCommitish": "main",
  "codeCompilationConfig": {
    "defaultDatabase": "${PROD_PROJECT}"
  },
  "cronSchedule": "0 */4 * * *"
}
EOF
)

if [ "${PROD_REL_CHECK}" = "404" ]; then
  echo "Creating prod-release configuration (targeting ${PROD_PROJECT})..."
  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PROD_REL_PAYLOAD}" \
    "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/releaseConfigs?releaseConfigId=prod-release" >/dev/null
  echo "✔ prod-release created."
else
  echo "✔ prod-release already exists."
fi

# Step 4: Create Workflow Configurations (dev-execution & prod-execution)
echo ""
echo "--- Step 4: Creating Workflow Execution Configurations ---"

# dev-execution
DEV_WF_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/workflowConfigs/dev-execution")

DEV_WF_PAYLOAD=$(cat <<EOF
{
  "releaseConfig": "projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/releaseConfigs/dev-release",
  "invocationConfig": {
    "serviceAccount": "${EXECUTOR_SA}"
  }
}
EOF
)

if [ "${DEV_WF_CHECK}" = "404" ]; then
  echo "Creating dev-execution workflow config (under ${EXECUTOR_SA})..."
  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${DEV_WF_PAYLOAD}" \
    "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/workflowConfigs?workflowConfigId=dev-execution" >/dev/null
  echo "✔ dev-execution created."
else
  echo "✔ dev-execution already exists."
fi

# prod-execution
PROD_WF_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/workflowConfigs/prod-execution")

PROD_WF_PAYLOAD=$(cat <<EOF
{
  "releaseConfig": "projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/releaseConfigs/prod-release",
  "cronSchedule": "0 6 * * *",
  "invocationConfig": {
    "serviceAccount": "${EXECUTOR_SA}"
  }
}
EOF
)

if [ "${PROD_WF_CHECK}" = "404" ]; then
  echo "Creating prod-execution workflow config (under ${EXECUTOR_SA})..."
  curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PROD_WF_PAYLOAD}" \
    "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/workflowConfigs?workflowConfigId=prod-execution" >/dev/null
  echo "✔ prod-execution created."
else
  echo "✔ prod-execution already exists."
fi

echo ""
echo "=== Step 7 Dataform Configurations Provisioned Successfully ==="
