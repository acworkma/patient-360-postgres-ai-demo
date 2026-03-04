#!/bin/bash
# =============================================================================
# Patient 360 - Pre-deployment Azure Resource Provisioning Script
# =============================================================================
# This script provisions all Azure resources required BEFORE running
# deploy-azure.sh:
#   - Azure Database for PostgreSQL Flexible Server (with azure_ai + pgvector)
#   - Azure AI Language (for PHI redaction)
#   - Azure AI Services + Foundry Project (for embeddings + chat, replaces
#     the deprecated standalone Azure OpenAI resource)
#   - Runs all SQL migrations to set up the database
#
# Usage:
#   chmod +x pre-deploy.sh
#   ./pre-deploy.sh
#
# Or override defaults via environment variables:
#   PG_SERVER_NAME=myserver PG_ADMIN_PASSWORD=MyP@ss ./pre-deploy.sh
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration — override via environment variables or edit defaults here
# -----------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-patient360-rg}"
LOCATION="${LOCATION:-eastus2}"

# PostgreSQL
PG_SERVER_NAME="${PG_SERVER_NAME:-patient360-pgserver}"
PG_ADMIN_USER="${PG_ADMIN_USER:-pgadmin}"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-}"
PG_DATABASE_NAME="${PG_DATABASE_NAME:-patient360}"
PG_SKU="${PG_SKU:-Standard_D2ds_v4}"
PG_VERSION="${PG_VERSION:-16}"
PG_STORAGE_SIZE="${PG_STORAGE_SIZE:-32}"

# Azure AI Language
AI_LANGUAGE_NAME="${AI_LANGUAGE_NAME:-patient360-language}"

# Azure AI Services (multi-service, provides OpenAI-compatible endpoint)
AI_SERVICES_NAME="${AI_SERVICES_NAME:-patient360-aiservices}"

# Azure AI Foundry Project (hubless)
FOUNDRY_PROJECT_NAME="${FOUNDRY_PROJECT_NAME:-patient360-foundry}"

# Model deployments
CHAT_MODEL="${CHAT_MODEL:-gpt-4o}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-text-embedding-3-small}"

# Optional: Cohere Rerank
COHERE_RERANK="${COHERE_RERANK:-false}"
COHERE_RERANK_ENDPOINT="${COHERE_RERANK_ENDPOINT:-}"
COHERE_RERANK_KEY="${COHERE_RERANK_KEY:-}"

# Output file
ENV_OUTPUT_FILE="${ENV_OUTPUT_FILE:-pre-deploy-output.env}"

# =============================================================================
# Helper functions
# =============================================================================
log_step() { echo ""; echo "===> $1"; }
log_ok()   { echo "  ✅ $1"; }
log_skip() { echo "  ⏭️  $1 (already exists)"; }
log_info() { echo "  ℹ️  $1"; }
log_warn() { echo "  ⚠️  $1"; }

resource_exists() {
    local type="$1"
    shift
    az "$type" show "$@" --output none 2>/dev/null
}

# =============================================================================
# Step 1: Pre-flight checks
# =============================================================================
log_step "Pre-flight checks"

# Verify az CLI
if ! command -v az &>/dev/null; then
    echo "ERROR: Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli"
    exit 1
fi
log_ok "Azure CLI found"

# Verify logged in
if ! az account show --output none 2>/dev/null; then
    echo "ERROR: Not logged in to Azure. Run 'az login' first."
    exit 1
fi
SUBSCRIPTION=$(az account show --query name -o tsv)
log_ok "Logged in to Azure (subscription: $SUBSCRIPTION)"

# Verify PG admin password is set
if [[ -z "$PG_ADMIN_PASSWORD" ]]; then
    echo "ERROR: PG_ADMIN_PASSWORD is required. Set via environment variable:"
    echo "  PG_ADMIN_PASSWORD='YourP@ssw0rd' ./pre-deploy.sh"
    exit 1
fi
log_ok "PG_ADMIN_PASSWORD is set"

# Register required providers
log_step "Registering resource providers"
for provider in Microsoft.DBforPostgreSQL Microsoft.CognitiveServices Microsoft.MachineLearningServices; do
    state=$(az provider show --namespace "$provider" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "$state" != "Registered" ]]; then
        az provider register --namespace "$provider" --wait
        log_ok "Registered $provider"
    else
        log_ok "$provider already registered"
    fi
done

# =============================================================================
# Step 2: Resource Group
# =============================================================================
log_step "Creating Resource Group: $RESOURCE_GROUP"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
log_ok "Resource Group ready"

# =============================================================================
# Step 3: Azure Database for PostgreSQL Flexible Server
# =============================================================================
log_step "Provisioning PostgreSQL Flexible Server: $PG_SERVER_NAME"

if resource_exists "postgres flexible-server" --name "$PG_SERVER_NAME" --resource-group "$RESOURCE_GROUP"; then
    log_skip "PostgreSQL server $PG_SERVER_NAME"
else
    az postgres flexible-server create \
        --name "$PG_SERVER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku-name "$PG_SKU" \
        --version "$PG_VERSION" \
        --storage-size "$PG_STORAGE_SIZE" \
        --admin-user "$PG_ADMIN_USER" \
        --admin-password "$PG_ADMIN_PASSWORD" \
        --database-name "$PG_DATABASE_NAME" \
        --public-access 0.0.0.0 \
        --yes \
        --output none
    log_ok "PostgreSQL server created"
fi

# Allowlist extensions
log_info "Allowlisting azure_ai and vector extensions"
az postgres flexible-server parameter set \
    --server-name "$PG_SERVER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name azure.extensions \
    --value azure_ai,vector \
    --output none
log_ok "Extensions allowlisted"

# Add caller's current IP to firewall
log_info "Adding current IP to PostgreSQL firewall"
CURRENT_IP=$(curl -s https://api.ipify.org || echo "")
if [[ -n "$CURRENT_IP" ]]; then
    az postgres flexible-server firewall-rule create \
        --server-name "$PG_SERVER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --rule-name "pre-deploy-caller" \
        --start-ip-address "$CURRENT_IP" \
        --end-ip-address "$CURRENT_IP" \
        --output none 2>/dev/null || true
    log_ok "Firewall rule added for $CURRENT_IP"
else
    log_warn "Could not detect current IP — you may need to add a firewall rule manually"
fi

PG_HOST="${PG_SERVER_NAME}.postgres.database.azure.com"

# =============================================================================
# Step 4: Azure AI Language
# =============================================================================
log_step "Provisioning Azure AI Language: $AI_LANGUAGE_NAME"

if resource_exists "cognitiveservices account" --name "$AI_LANGUAGE_NAME" --resource-group "$RESOURCE_GROUP"; then
    log_skip "AI Language resource $AI_LANGUAGE_NAME"
else
    az cognitiveservices account create \
        --name "$AI_LANGUAGE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --kind TextAnalytics \
        --sku S \
        --yes \
        --output none
    log_ok "AI Language resource created"
fi

AI_LANGUAGE_ENDPOINT=$(az cognitiveservices account show \
    --name "$AI_LANGUAGE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query properties.endpoint -o tsv)
AI_LANGUAGE_KEY=$(az cognitiveservices account keys list \
    --name "$AI_LANGUAGE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query key1 -o tsv)
log_ok "AI Language endpoint: $AI_LANGUAGE_ENDPOINT"

# =============================================================================
# Step 5: Azure AI Services (multi-service resource for OpenAI-compatible API)
# =============================================================================
log_step "Provisioning Azure AI Services: $AI_SERVICES_NAME"

if resource_exists "cognitiveservices account" --name "$AI_SERVICES_NAME" --resource-group "$RESOURCE_GROUP"; then
    log_skip "AI Services resource $AI_SERVICES_NAME"
else
    az cognitiveservices account create \
        --name "$AI_SERVICES_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --kind AIServices \
        --sku S0 \
        --yes \
        --output none
    log_ok "AI Services resource created"
fi

AI_SERVICES_ENDPOINT=$(az cognitiveservices account show \
    --name "$AI_SERVICES_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query properties.endpoint -o tsv)
AI_SERVICES_KEY=$(az cognitiveservices account keys list \
    --name "$AI_SERVICES_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query key1 -o tsv)
log_ok "AI Services endpoint: $AI_SERVICES_ENDPOINT"

# =============================================================================
# Step 6: Deploy models via AI Services
# =============================================================================
log_step "Deploying models"

# Deploy embedding model
log_info "Deploying $EMBEDDING_MODEL"
if az cognitiveservices account deployment show \
    --name "$AI_SERVICES_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --deployment-name "$EMBEDDING_MODEL" \
    --output none 2>/dev/null; then
    log_skip "Deployment $EMBEDDING_MODEL"
else
    az cognitiveservices account deployment create \
        --name "$AI_SERVICES_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --deployment-name "$EMBEDDING_MODEL" \
        --model-name "$EMBEDDING_MODEL" \
        --model-version "1" \
        --model-format OpenAI \
        --sku-capacity 120 \
        --sku-name Standard \
        --output none
    log_ok "$EMBEDDING_MODEL deployed"
fi

# Deploy chat model
log_info "Deploying $CHAT_MODEL"
if az cognitiveservices account deployment show \
    --name "$AI_SERVICES_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --deployment-name "$CHAT_MODEL" \
    --output none 2>/dev/null; then
    log_skip "Deployment $CHAT_MODEL"
else
    az cognitiveservices account deployment create \
        --name "$AI_SERVICES_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --deployment-name "$CHAT_MODEL" \
        --model-name "$CHAT_MODEL" \
        --model-version "2024-08-06" \
        --model-format OpenAI \
        --sku-capacity 80 \
        --sku-name Standard \
        --output none
    log_ok "$CHAT_MODEL deployed"
fi

# =============================================================================
# Step 7: Create Azure AI Foundry Project (hubless)
# =============================================================================
log_step "Provisioning Azure AI Foundry project: $FOUNDRY_PROJECT_NAME"

# Check if the ai extension is available; install if needed
if ! az extension show --name ml --output none 2>/dev/null; then
    log_info "Installing Azure ML CLI extension (required for Foundry projects)"
    az extension add --name ml --yes --output none
fi

AI_SERVICES_RESOURCE_ID=$(az cognitiveservices account show \
    --name "$AI_SERVICES_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv)

if az ml workspace show \
    --name "$FOUNDRY_PROJECT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --output none 2>/dev/null; then
    log_skip "Foundry project $FOUNDRY_PROJECT_NAME"
else
    az ml workspace create \
        --name "$FOUNDRY_PROJECT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --kind project \
        --ai-resource "$AI_SERVICES_RESOURCE_ID" \
        --output none
    log_ok "Foundry project created"
fi

# Retrieve the Foundry project connection string / endpoint
FOUNDRY_DISCOVERY_URL=$(az ml workspace show \
    --name "$FOUNDRY_PROJECT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query discovery_url -o tsv 2>/dev/null || echo "")
FOUNDRY_WORKSPACE_ID=$(az ml workspace show \
    --name "$FOUNDRY_PROJECT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv 2>/dev/null || echo "")
log_ok "Foundry project ready"

# =============================================================================
# Step 8: Run SQL Migrations
# =============================================================================
log_step "Running SQL migrations"

# Determine SQL client
PSQL_CMD=""
if command -v psql &>/dev/null; then
    PSQL_CMD="psql"
    log_ok "Using psql client"
else
    log_warn "psql not found — attempting to install postgresql-client"
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client >/dev/null 2>&1
        PSQL_CMD="psql"
    fi
fi

if [[ -z "$PSQL_CMD" ]]; then
    echo "ERROR: psql client not available. Install postgresql-client or run migrations manually."
    echo "       Connection string: postgresql://$PG_ADMIN_USER:****@$PG_HOST:5432/$PG_DATABASE_NAME?sslmode=require"
    exit 1
fi

PGCONNSTR="host=$PG_HOST port=5432 dbname=$PG_DATABASE_NAME user=$PG_ADMIN_USER password=$PG_ADMIN_PASSWORD sslmode=require"

run_migration() {
    local file="$1"
    local label
    label=$(basename "$file")
    log_info "Running $label"
    psql "$PGCONNSTR" -f "$file" -v ON_ERROR_STOP=1 > /dev/null 2>&1
    log_ok "$label"
}

# Migration 001: Enable extensions
run_migration "db/migrations/001_enable_extensions.sql"

# Migration 005: Configure Azure AI — dynamically template credentials
log_info "Templating migration 005 with provisioned credentials"
MIGRATION_005_TEMP=$(mktemp)
sed \
    -e "s|https://YOUR-AI-LANGUAGE-RESOURCE.cognitiveservices.azure.com|$AI_LANGUAGE_ENDPOINT|g" \
    -e "s|YOUR-AZURE-AI-LANGUAGE-KEY|$AI_LANGUAGE_KEY|g" \
    -e "s|https://YOUR-OPENAI-RESOURCE.openai.azure.com|$AI_SERVICES_ENDPOINT|g" \
    -e "s|YOUR-AZURE-OPENAI-KEY|$AI_SERVICES_KEY|g" \
    db/migrations/005_configure_azure_ai.sql > "$MIGRATION_005_TEMP"

# Uncomment the OpenAI settings lines (they're commented out by default)
sed -i \
    -e "s|^-- SELECT azure_ai.set_setting('azure_openai.endpoint'|SELECT azure_ai.set_setting('azure_openai.endpoint'|g" \
    -e "s|^-- SELECT azure_ai.set_setting('azure_openai.subscription_key'|SELECT azure_ai.set_setting('azure_openai.subscription_key'|g" \
    "$MIGRATION_005_TEMP"

psql "$PGCONNSTR" -f "$MIGRATION_005_TEMP" -v ON_ERROR_STOP=1 > /dev/null 2>&1
rm -f "$MIGRATION_005_TEMP"
log_ok "005_configure_azure_ai.sql (templated)"

# Remaining migrations
run_migration "db/migrations/010_schema.sql"
run_migration "db/migrations/020_functions_redact_ingest.sql"
run_migration "db/migrations/030_seed.sql"
run_migration "db/migrations/040_clinical_actions.sql"

# Migration 050: Cohere rerank (optional)
if [[ "$COHERE_RERANK" == "true" && -n "$COHERE_RERANK_ENDPOINT" && -n "$COHERE_RERANK_KEY" ]]; then
    MIGRATION_050_TEMP=$(mktemp)
    sed \
        -e "s|https://ai-gateway-amitmukh.azure-api.net/foundrynextgen-resource/v1/rerank|$COHERE_RERANK_ENDPOINT|g" \
        -e "s|86a359eedb16456ca4b161f442f0eff9|$COHERE_RERANK_KEY|g" \
        db/migrations/050_configure_semantic_operators.sql > "$MIGRATION_050_TEMP"
    psql "$PGCONNSTR" -f "$MIGRATION_050_TEMP" -v ON_ERROR_STOP=1 > /dev/null 2>&1
    rm -f "$MIGRATION_050_TEMP"
    log_ok "050_configure_semantic_operators.sql (templated)"
else
    log_skip "050_configure_semantic_operators.sql (COHERE_RERANK not enabled)"
fi

run_migration "db/migrations/060_enhanced_retrieval_reranking.sql"

log_ok "All migrations complete"

# =============================================================================
# Step 9: Verification
# =============================================================================
log_step "Verification"

PATIENT_COUNT=$(psql "$PGCONNSTR" -t -A -c "SELECT count(*) FROM patients;" 2>/dev/null || echo "0")
if [[ "$PATIENT_COUNT" -gt 0 ]]; then
    log_ok "Database seeded: $PATIENT_COUNT patient(s) found"
else
    log_warn "No patients found — seed data may not have loaded"
fi

# =============================================================================
# Step 10: Write output env file
# =============================================================================
log_step "Writing $ENV_OUTPUT_FILE"

DATABASE_URL="postgresql://${PG_ADMIN_USER}:${PG_ADMIN_PASSWORD}@${PG_HOST}:5432/${PG_DATABASE_NAME}?sslmode=require"

cat > "$ENV_OUTPUT_FILE" <<EOF
# =============================================================================
# Patient 360 - Pre-deployment Output
# Generated by pre-deploy.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

# Database
DATABASE_URL=${DATABASE_URL}
DB_HOST=${PG_HOST}
DB_NAME=${PG_DATABASE_NAME}
DB_USER=${PG_ADMIN_USER}
DB_PASSWORD=${PG_ADMIN_PASSWORD}

# Azure AI Language (PHI redaction)
AZURE_AI_ENDPOINT=${AI_LANGUAGE_ENDPOINT}
AZURE_AI_KEY=${AI_LANGUAGE_KEY}

# Azure AI Services (OpenAI-compatible endpoint for DB extensions)
AZURE_AI_SERVICES_ENDPOINT=${AI_SERVICES_ENDPOINT}
AZURE_AI_SERVICES_KEY=${AI_SERVICES_KEY}

# Azure AI Foundry Project (for Python backend SDK)
AZURE_AI_PROJECT_ENDPOINT=${FOUNDRY_DISCOVERY_URL}
AZURE_AI_PROJECT_ID=${FOUNDRY_WORKSPACE_ID}

# Model deployments
AZURE_OPENAI_CHAT_DEPLOYMENT=${CHAT_MODEL}
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=${EMBEDDING_MODEL}

# Resource identifiers (for deploy-azure.sh)
RESOURCE_GROUP=${RESOURCE_GROUP}
LOCATION=${LOCATION}
EOF

log_ok "$ENV_OUTPUT_FILE written"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================================================="
echo "  Pre-deployment Complete!"
echo "============================================================================="
echo ""
echo "  Resource Group:      $RESOURCE_GROUP ($LOCATION)"
echo "  PostgreSQL Server:   $PG_HOST"
echo "  PostgreSQL Database: $PG_DATABASE_NAME"
echo "  AI Language:         $AI_LANGUAGE_ENDPOINT"
echo "  AI Services:         $AI_SERVICES_ENDPOINT"
echo "  Foundry Project:     $FOUNDRY_PROJECT_NAME"
echo "  Chat Model:          $CHAT_MODEL"
echo "  Embedding Model:     $EMBEDDING_MODEL"
echo "  Patients Seeded:     $PATIENT_COUNT"
echo ""
echo "  Output written to:   $ENV_OUTPUT_FILE"
echo ""
echo "  Next step:"
echo "    ./deploy-azure.sh"
echo ""
echo "  For production, consider switching to Entra ID managed identity"
echo "  instead of API keys. See README.md for details."
echo ""
echo "============================================================================="
