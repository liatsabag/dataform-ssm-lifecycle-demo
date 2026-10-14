#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Google Cloud Dataform Multi-Project Demo - Master Automated Deployment
# Sequentially executes Steps 01 through 10 to establish a complete demo environment.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "🚀 STARTING COMPLETE DATAFORM DEMO ENVIRONMENT DEPLOYMENT"
echo "==================================================================="
echo "DEV Project : ${DEV_PROJECT}"
echo "PROD Project: ${PROD_PROJECT}"
echo "SSM Project : ${SSM_PROJECT}"
echo "Location    : ${LOCATION}"
echo "Developer   : ${DEVELOPER}"
echo "==================================================================="
echo ""

run_step() {
  local script_name="$1"
  local step_desc="$2"
  
  echo "-------------------------------------------------------------------"
  echo "▶ ${step_desc} (${script_name})"
  echo "-------------------------------------------------------------------"
  
  if [ -f "${SCRIPT_DIR}/${script_name}" ]; then
    bash "${SCRIPT_DIR}/${script_name}"
    echo "✔ Completed: ${step_desc}"
    echo ""
  else
    echo "❌ Error: Script ${script_name} not found!"
    exit 1
  fi
}

START_TIME=$(date +%s)

# Sequence of Deployment Steps (01 to 10)
run_step "01_provision_projects.sh"               "Step 1: Provision Projects & Enable GCP APIs"
run_step "02_create_datasets.sh"                 "Step 2: Create Core BigQuery Datasets"
run_step "03_seed_prod_data.sh"                  "Step 3: Seed Raw Vault Transactions in PROD"
run_step "04_configure_iam_security.sh"          "Step 4: Configure Service Accounts & Least-Privilege IAM"
run_step "05_verify_security_boundaries.sh"       "Step 5: Verify Security Boundaries & Data Isolation"
run_step "06_provision_secure_source_manager.sh" "Step 6: Provision SSM Instance, Repo & Dev Connect"
run_step "07_create_dataform_configs.sh"         "Step 7: Create Dataform Repo, Workspaces & Release Configs"
run_step "08_verify_ssm_pipeline.sh"             "Step 8: Verify SSM & Dev Connect Git Proxy Connectivity"
run_step "09_execute_elt_pipeline.sh"            "Step 9: Execute Baseline 3-Tier ELT Pipeline"
run_step "10_verify_pipeline_and_assertions.sh"  "Step 10: Verify Curated Tables & Dataform Assertions"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "==================================================================="
echo "🎉 ALL DEPLOYMENT & VERIFICATION STEPS COMPLETED SUCCESSFULLY!"
echo "⏱ Total Provisioning Time: $((DURATION / 60)) min $((DURATION % 60)) sec"
echo "==================================================================="
echo "Your environment is fully initialized and ready for the demo."
echo ""
echo "Next actions:"
echo " • To present the demo, follow DEMO_SCRIPT.md and DEMO_GUIDE.md in Google Cloud Console."
echo " • To reset back to baseline at any point, run: ./scripts/12_reset_demo_state.sh"
echo "==================================================================="
