#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 1: Provisioning 3 Projects (DEV, PROD, SSM) & Enabling GCP APIs
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# Auto-discover Billing Account ID if not explicitly set
if [ -z "${BILLING_ID:-}" ]; then
  echo ">>> Auto-detecting active Billing Account..."
  BILLING_ID=$(gcloud billing projects describe "${SSM_PROJECT}" --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||' || true)
  if [ -z "${BILLING_ID}" ]; then
    BILLING_ID=$(gcloud billing accounts list --filter="open=true" --format="value(ACCOUNT_ID)" --limit=1 2>/dev/null || true)
  fi
  if [ -n "${BILLING_ID}" ]; then
    echo "✔ Auto-detected Billing Account: ${BILLING_ID}"
  fi
fi

# Auto-discover Folder ID from SSM_PROJECT if not explicitly set
if [ -z "${FOLDER_ID:-}" ]; then
  echo ">>> Auto-detecting parent folder from ${SSM_PROJECT}..."
  PARENT_TYPE=$(gcloud projects describe "${SSM_PROJECT}" --format="value(parent.type)" 2>/dev/null || true)
  if [ "${PARENT_TYPE}" = "folder" ]; then
    FOLDER_ID=$(gcloud projects describe "${SSM_PROJECT}" --format="value(parent.id)" 2>/dev/null || true)
    echo "✔ Auto-detected parent Folder ID: ${FOLDER_ID}"
  else
    FOLDER_ID=""
  fi
fi

echo "==================================================================="
echo "=== Step 1: Provisioning Projects & Enabling APIs               ==="
echo "==================================================================="
echo "DEV Project : ${DEV_PROJECT}"
echo "PROD Project: ${PROD_PROJECT}"
echo "SSM Project : ${SSM_PROJECT}"
echo "Billing ID  : ${BILLING_ID:-<Auto/Unset>}"
echo "Folder ID   : ${FOLDER_ID:-<Root/Unset>}"
echo "==================================================================="

# Function to provision or validate a project
provision_project() {
  local proj="$1"
  local name="$2"
  
  echo ">>> Checking project: ${proj}..."
  if ! gcloud projects describe "${proj}" >/dev/null 2>&1; then
    echo "Creating project ${proj} (${name})..."
    if [ -n "${FOLDER_ID}" ]; then
      gcloud projects create "${proj}" --name="${name}" --folder="${FOLDER_ID}" || \
      gcloud projects create "${proj}" --name="${name}"
    else
      gcloud projects create "${proj}" --name="${name}"
    fi
  else
    echo "✔ Project ${proj} already exists."
  fi

  if [ -n "${BILLING_ID}" ]; then
    echo "Linking billing account ${BILLING_ID} to ${proj}..."
    gcloud billing projects link "${proj}" --billing-account="${BILLING_ID}" 2>/dev/null || \
    gcloud billing projects link "${proj}" --billing-account="${BILLING_ID}" --billing-project="${proj}" 2>/dev/null || true
  fi
}

# 1. Provision all 3 projects
provision_project "${DEV_PROJECT}" "Dataform DEV"
provision_project "${PROD_PROJECT}" "Dataform PROD"
provision_project "${SSM_PROJECT}" "Secure Source Manager Host"

# 2. Enable Required APIs
echo ""
echo "=== Enabling Required Google Cloud APIs ==="
DATA_APIS=(
  "bigquery.googleapis.com"
  "dataform.googleapis.com"
  "developerconnect.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "iam.googleapis.com"
  "cloudbilling.googleapis.com"
)

SSM_APIS=(
  "securesourcemanager.googleapis.com"
  "developerconnect.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "iam.googleapis.com"
)

echo "Enabling APIs in DEV (${DEV_PROJECT})..."
gcloud services enable "${DATA_APIS[@]}" --project="${DEV_PROJECT}"

echo "Enabling APIs in PROD (${PROD_PROJECT})..."
gcloud services enable "${DATA_APIS[@]}" --project="${PROD_PROJECT}"

echo "Enabling APIs in SSM Host (${SSM_PROJECT})..."
gcloud services enable "${SSM_APIS[@]}" --project="${SSM_PROJECT}"

echo ""
echo "=== Projects & APIs Provisioned Successfully ==="
