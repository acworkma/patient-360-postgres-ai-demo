# =============================================================================
# Patient 360 - Pre-deployment Azure Resource Provisioning Script (PowerShell)
# =============================================================================
# This script provisions all Azure resources required BEFORE running
# deploy-azure.ps1:
#   - Azure Database for PostgreSQL Flexible Server (with azure_ai + pgvector)
#   - Azure AI Language (for PHI redaction)
#   - Azure AI Services + Foundry Project (for embeddings + chat, replaces
#     the deprecated standalone Azure OpenAI resource)
#   - Runs all SQL migrations to set up the database
#
# Usage:
#   $env:PG_ADMIN_PASSWORD = "YourP@ssw0rd"
#   .\pre-deploy.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Configuration — override via environment variables or edit defaults here
# -----------------------------------------------------------------------------
$RESOURCE_GROUP    = if ($env:RESOURCE_GROUP)    { $env:RESOURCE_GROUP }    else { "patient360-rg" }
$LOCATION          = if ($env:LOCATION)          { $env:LOCATION }          else { "eastus2" }

# PostgreSQL (deployed to a separate region if PG is restricted in LOCATION)
$PG_LOCATION       = if ($env:PG_LOCATION)       { $env:PG_LOCATION }       else { "centralus" }
$PG_SERVER_NAME    = if ($env:PG_SERVER_NAME)    { $env:PG_SERVER_NAME }    else { "patient360-pgserver" }
$PG_ADMIN_USER     = if ($env:PG_ADMIN_USER)     { $env:PG_ADMIN_USER }     else { "pgadmin" }
$PG_ADMIN_PASSWORD = if ($env:PG_ADMIN_PASSWORD) { $env:PG_ADMIN_PASSWORD } else { throw "Set `$env:PG_ADMIN_PASSWORD before running" }
$PG_DATABASE_NAME  = if ($env:PG_DATABASE_NAME)  { $env:PG_DATABASE_NAME }  else { "patient360" }
$PG_SKU            = if ($env:PG_SKU)            { $env:PG_SKU }            else { "Standard_D2ds_v4" }
$PG_VERSION        = if ($env:PG_VERSION)        { $env:PG_VERSION }        else { "16" }
$PG_STORAGE_SIZE   = if ($env:PG_STORAGE_SIZE)   { $env:PG_STORAGE_SIZE }   else { "32" }

# Azure AI Language
$AI_LANGUAGE_NAME  = if ($env:AI_LANGUAGE_NAME)  { $env:AI_LANGUAGE_NAME }  else { "patient360-language" }

# Azure AI Services
$AI_SERVICES_NAME  = if ($env:AI_SERVICES_NAME)  { $env:AI_SERVICES_NAME }  else { "patient360-aiservices" }

# Azure AI Foundry Project (hubless)
$FOUNDRY_PROJECT_NAME = if ($env:FOUNDRY_PROJECT_NAME) { $env:FOUNDRY_PROJECT_NAME } else { "patient360-foundry" }

# Model deployments
$CHAT_MODEL        = if ($env:CHAT_MODEL)        { $env:CHAT_MODEL }        else { "gpt-4o" }
$EMBEDDING_MODEL   = if ($env:EMBEDDING_MODEL)   { $env:EMBEDDING_MODEL }   else { "text-embedding-3-small" }

# Optional: Cohere Rerank
$COHERE_RERANK          = if ($env:COHERE_RERANK)          { $env:COHERE_RERANK }          else { "false" }
$COHERE_RERANK_ENDPOINT = if ($env:COHERE_RERANK_ENDPOINT) { $env:COHERE_RERANK_ENDPOINT } else { "" }
$COHERE_RERANK_KEY      = if ($env:COHERE_RERANK_KEY)      { $env:COHERE_RERANK_KEY }      else { "" }

# Output file
$ENV_OUTPUT_FILE = if ($env:ENV_OUTPUT_FILE) { $env:ENV_OUTPUT_FILE } else { "pre-deploy-output.env" }

# =============================================================================
# Helper functions
# =============================================================================
function Log-Step  { param([string]$msg) Write-Host "`n===> $msg" -ForegroundColor Cyan }
function Log-Ok    { param([string]$msg) Write-Host "  ✅ $msg" -ForegroundColor Green }
function Log-Skip  { param([string]$msg) Write-Host "  ⏭️  $msg (already exists)" -ForegroundColor Yellow }
function Log-Info  { param([string]$msg) Write-Host "  ℹ️  $msg" -ForegroundColor Gray }
function Log-Warn  { param([string]$msg) Write-Host "  ⚠️  $msg" -ForegroundColor DarkYellow }

function ResourceExists {
    param([string]$type, [string[]]$args)
    try {
        $null = az @($type, "show") @args --output none 2>$null
        return $true
    } catch {
        return $false
    }
}

# =============================================================================
# Step 1: Pre-flight checks
# =============================================================================
Log-Step "Pre-flight checks"

# Verify az CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli"
}
Log-Ok "Azure CLI found"

# Verify logged in
try { $null = az account show --output none 2>$null } catch {
    throw "Not logged in to Azure. Run 'az login' first."
}
$SUBSCRIPTION = az account show --query name -o tsv
Log-Ok "Logged in to Azure (subscription: $SUBSCRIPTION)"

# Register required providers
Log-Step "Registering resource providers"
foreach ($provider in @("Microsoft.DBforPostgreSQL", "Microsoft.CognitiveServices", "Microsoft.MachineLearningServices")) {
    $state = az provider show --namespace $provider --query "registrationState" -o tsv 2>$null
    if ($state -ne "Registered") {
        az provider register --namespace $provider --wait
        Log-Ok "Registered $provider"
    } else {
        Log-Ok "$provider already registered"
    }
}

# =============================================================================
# Step 2: Resource Group
# =============================================================================
Log-Step "Creating Resource Group: $RESOURCE_GROUP"
az group create --name $RESOURCE_GROUP --location $LOCATION --output none
Log-Ok "Resource Group ready"

# =============================================================================
# Step 3: Azure Database for PostgreSQL Flexible Server
# =============================================================================
Log-Step "Provisioning PostgreSQL Flexible Server: $PG_SERVER_NAME"

$pgExists = az postgres flexible-server show --name $PG_SERVER_NAME --resource-group $RESOURCE_GROUP --output none 2>$null; $?
if ($LASTEXITCODE -eq 0) {
    Log-Skip "PostgreSQL server $PG_SERVER_NAME"
} else {
    Log-Info "Using PG_LOCATION=$PG_LOCATION (main LOCATION=$LOCATION)"
    az postgres flexible-server create `
        --name $PG_SERVER_NAME `
        --resource-group $RESOURCE_GROUP `
        --location $PG_LOCATION `
        --sku-name $PG_SKU `
        --version $PG_VERSION `
        --storage-size $PG_STORAGE_SIZE `
        --admin-user $PG_ADMIN_USER `
        --admin-password $PG_ADMIN_PASSWORD `
        --public-access 0.0.0.0 `
        --yes `
        --output none
    Log-Ok "PostgreSQL server created"
}

# Create the database if it doesn't exist
Log-Info "Ensuring database $PG_DATABASE_NAME exists"
az postgres flexible-server db create `
    --server-name $PG_SERVER_NAME `
    --resource-group $RESOURCE_GROUP `
    --database-name $PG_DATABASE_NAME `
    --output none 2>$null
Log-Ok "Database $PG_DATABASE_NAME ready"

# Allowlist extensions
Log-Info "Allowlisting azure_ai and vector extensions"
az postgres flexible-server parameter set `
    --server-name $PG_SERVER_NAME `
    --resource-group $RESOURCE_GROUP `
    --name azure.extensions `
    --value azure_ai,vector `
    --output none
Log-Ok "Extensions allowlisted"

# Add caller's current IP to firewall
Log-Info "Adding current IP to PostgreSQL firewall"
try {
    $CURRENT_IP = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10)
    az postgres flexible-server firewall-rule create `
        --server-name $PG_SERVER_NAME `
        --resource-group $RESOURCE_GROUP `
        --rule-name "pre-deploy-caller" `
        --start-ip-address $CURRENT_IP `
        --end-ip-address $CURRENT_IP `
        --output none 2>$null
    Log-Ok "Firewall rule added for $CURRENT_IP"
} catch {
    Log-Warn "Could not detect current IP — you may need to add a firewall rule manually"
}

$PG_HOST = "$PG_SERVER_NAME.postgres.database.azure.com"

# Enable system-assigned managed identity on PostgreSQL server
Log-Info "Enabling system-assigned managed identity on PostgreSQL server"
try {
    az postgres flexible-server identity assign `
        --server-name $PG_SERVER_NAME `
        --resource-group $RESOURCE_GROUP `
        --output none 2>$null
} catch { }
$PG_PRINCIPAL_ID = az postgres flexible-server show `
    --name $PG_SERVER_NAME `
    --resource-group $RESOURCE_GROUP `
    --query identity.principalId -o tsv 2>$null
if ($PG_PRINCIPAL_ID -and $PG_PRINCIPAL_ID -ne "None") {
    Log-Ok "PostgreSQL managed identity principal: $PG_PRINCIPAL_ID"
} else {
    Log-Warn "Could not retrieve PG managed identity principal ID — RBAC role assignment may need to be done manually"
}

# =============================================================================
# Step 4: Azure AI Language
# =============================================================================
Log-Step "Provisioning Azure AI Language: $AI_LANGUAGE_NAME"

$langExists = az cognitiveservices account show --name $AI_LANGUAGE_NAME --resource-group $RESOURCE_GROUP --output none 2>$null; $?
if ($LASTEXITCODE -eq 0) {
    Log-Skip "AI Language resource $AI_LANGUAGE_NAME"
} else {
    az cognitiveservices account create `
        --name $AI_LANGUAGE_NAME `
        --resource-group $RESOURCE_GROUP `
        --location $LOCATION `
        --kind TextAnalytics `
        --sku S `
        --yes `
        --output none
    Log-Ok "AI Language resource created"
}

$AI_LANGUAGE_ENDPOINT = az cognitiveservices account show `
    --name $AI_LANGUAGE_NAME `
    --resource-group $RESOURCE_GROUP `
    --query properties.endpoint -o tsv
$AI_LANGUAGE_RESOURCE_ID = az cognitiveservices account show `
    --name $AI_LANGUAGE_NAME `
    --resource-group $RESOURCE_GROUP `
    --query id -o tsv
Log-Ok "AI Language endpoint: $AI_LANGUAGE_ENDPOINT"

# Grant "Cognitive Services User" role to PG managed identity on AI Language
if ($PG_PRINCIPAL_ID -and $PG_PRINCIPAL_ID -ne "None") {
    Log-Info "Granting Cognitive Services User role on AI Language to PG managed identity"
    try {
        az role assignment create `
            --assignee-object-id $PG_PRINCIPAL_ID `
            --assignee-principal-type ServicePrincipal `
            --role "Cognitive Services User" `
            --scope $AI_LANGUAGE_RESOURCE_ID `
            --output none 2>$null
        Log-Ok "RBAC role assigned on AI Language"
    } catch {
        Log-Warn "Could not assign RBAC role on AI Language — may need manual assignment"
    }
}

# =============================================================================
# Step 5: Azure AI Services
# =============================================================================
Log-Step "Provisioning Azure AI Services: $AI_SERVICES_NAME"

$svcExists = az cognitiveservices account show --name $AI_SERVICES_NAME --resource-group $RESOURCE_GROUP --output none 2>$null; $?
if ($LASTEXITCODE -eq 0) {
    Log-Skip "AI Services resource $AI_SERVICES_NAME"
} else {
    az cognitiveservices account create `
        --name $AI_SERVICES_NAME `
        --resource-group $RESOURCE_GROUP `
        --location $LOCATION `
        --kind AIServices `
        --sku S0 `
        --yes `
        --output none
    Log-Ok "AI Services resource created"
}

$AI_SERVICES_ENDPOINT = az cognitiveservices account show `
    --name $AI_SERVICES_NAME `
    --resource-group $RESOURCE_GROUP `
    --query properties.endpoint -o tsv
$AI_SERVICES_RESOURCE_ID_FOR_RBAC = az cognitiveservices account show `
    --name $AI_SERVICES_NAME `
    --resource-group $RESOURCE_GROUP `
    --query id -o tsv
# Try to get the key; if disableLocalAuth is enabled, fall back to managed identity
try {
    $AI_SERVICES_KEY = az cognitiveservices account keys list `
        --name $AI_SERVICES_NAME `
        --resource-group $RESOURCE_GROUP `
        --query key1 -o tsv 2>$null
} catch {
    $AI_SERVICES_KEY = ""
}
Log-Ok "AI Services endpoint: $AI_SERVICES_ENDPOINT"
if (-not $AI_SERVICES_KEY) {
    Log-Info "AI Services key not available (disableLocalAuth policy) — using managed identity"
}

# Grant "Cognitive Services User" role to PG managed identity on AI Services
if ($PG_PRINCIPAL_ID -and $PG_PRINCIPAL_ID -ne "None") {
    Log-Info "Granting Cognitive Services User role on AI Services to PG managed identity"
    try {
        az role assignment create `
            --assignee-object-id $PG_PRINCIPAL_ID `
            --assignee-principal-type ServicePrincipal `
            --role "Cognitive Services User" `
            --scope $AI_SERVICES_RESOURCE_ID_FOR_RBAC `
            --output none 2>$null
        Log-Ok "RBAC role assigned on AI Services"
    } catch {
        Log-Warn "Could not assign RBAC role on AI Services — may need manual assignment"
    }
}

# =============================================================================
# Step 6: Deploy models
# =============================================================================
Log-Step "Deploying models"

# Deploy embedding model
Log-Info "Deploying $EMBEDDING_MODEL"
$embExists = az cognitiveservices account deployment show --name $AI_SERVICES_NAME --resource-group $RESOURCE_GROUP --deployment-name $EMBEDDING_MODEL --output none 2>$null; $?
if ($LASTEXITCODE -eq 0) {
    Log-Skip "Deployment $EMBEDDING_MODEL"
} else {
    az cognitiveservices account deployment create `
        --name $AI_SERVICES_NAME `
        --resource-group $RESOURCE_GROUP `
        --deployment-name $EMBEDDING_MODEL `
        --model-name $EMBEDDING_MODEL `
        --model-version "1" `
        --model-format OpenAI `
        --sku-capacity 120 `
        --sku-name Standard `
        --output none
    Log-Ok "$EMBEDDING_MODEL deployed"
}

# Deploy chat model
Log-Info "Deploying $CHAT_MODEL"
$chatExists = az cognitiveservices account deployment show --name $AI_SERVICES_NAME --resource-group $RESOURCE_GROUP --deployment-name $CHAT_MODEL --output none 2>$null; $?
if ($LASTEXITCODE -eq 0) {
    Log-Skip "Deployment $CHAT_MODEL"
} else {
    az cognitiveservices account deployment create `
        --name $AI_SERVICES_NAME `
        --resource-group $RESOURCE_GROUP `
        --deployment-name $CHAT_MODEL `
        --model-name $CHAT_MODEL `
        --model-version "2024-08-06" `
        --model-format OpenAI `
        --sku-capacity 80 `
        --sku-name Standard `
        --output none
    Log-Ok "$CHAT_MODEL deployed"
}

# =============================================================================
# Step 7: Azure AI Foundry Project (hubless)
# =============================================================================
Log-Step "Provisioning Azure AI Foundry project: $FOUNDRY_PROJECT_NAME"

# Ensure ml extension is installed
$mlExt = az extension show --name ml --output none 2>$null; $?
if ($LASTEXITCODE -ne 0) {
    Log-Info "Installing Azure ML CLI extension (required for Foundry projects)"
    az extension add --name ml --yes --output none
}

$AI_SERVICES_RESOURCE_ID = az cognitiveservices account show `
    --name $AI_SERVICES_NAME `
    --resource-group $RESOURCE_GROUP `
    --query id -o tsv

$projExists = az ml workspace show --name $FOUNDRY_PROJECT_NAME --resource-group $RESOURCE_GROUP --output none 2>$null; $?
if ($LASTEXITCODE -eq 0) {
    Log-Skip "Foundry project $FOUNDRY_PROJECT_NAME"
} else {
    az ml workspace create `
        --name $FOUNDRY_PROJECT_NAME `
        --resource-group $RESOURCE_GROUP `
        --location $LOCATION `
        --kind project `
        --ai-resource $AI_SERVICES_RESOURCE_ID `
        --output none
    Log-Ok "Foundry project created"
}

$FOUNDRY_DISCOVERY_URL = az ml workspace show `
    --name $FOUNDRY_PROJECT_NAME `
    --resource-group $RESOURCE_GROUP `
    --query discovery_url -o tsv 2>$null
$FOUNDRY_WORKSPACE_ID = az ml workspace show `
    --name $FOUNDRY_PROJECT_NAME `
    --resource-group $RESOURCE_GROUP `
    --query id -o tsv 2>$null
Log-Ok "Foundry project ready"

# =============================================================================
# Step 8: Run SQL Migrations
# =============================================================================
Log-Step "Running SQL migrations"

# Check for psql
$PSQL_AVAILABLE = $false
if (Get-Command psql -ErrorAction SilentlyContinue) {
    $PSQL_AVAILABLE = $true
    Log-Ok "Using psql client"
} else {
    Log-Warn "psql not found — please install PostgreSQL client tools"
    Log-Warn "Skipping migrations. Run them manually using:"
    Log-Warn "  psql `"host=$PG_HOST port=5432 dbname=$PG_DATABASE_NAME user=$PG_ADMIN_USER password=*** sslmode=require`""
}

if ($PSQL_AVAILABLE) {
    $env:PGPASSWORD = $PG_ADMIN_PASSWORD
    $PGCONN = "host=$PG_HOST port=5432 dbname=$PG_DATABASE_NAME user=$PG_ADMIN_USER sslmode=require"

    function Run-Migration {
        param([string]$file)
        $label = Split-Path $file -Leaf
        Log-Info "Running $label"
        psql $PGCONN -f $file -v ON_ERROR_STOP=1 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Migration failed: $label" }
        Log-Ok "$label"
    }

    # Migration 001
    Run-Migration "db/migrations/001_enable_extensions.sql"

    # Migration 005: Template with actual credentials
    Log-Info "Templating migration 005 with provisioned credentials (managed identity)"
    $migration005Content = Get-Content "db/migrations/005_configure_azure_ai.sql" -Raw
    $migration005Content = $migration005Content `
        -replace "https://YOUR-AI-LANGUAGE-RESOURCE.cognitiveservices.azure.com", $AI_LANGUAGE_ENDPOINT `
        -replace "https://YOUR-OPENAI-RESOURCE.openai.azure.com", $AI_SERVICES_ENDPOINT
    # Uncomment OpenAI endpoint (managed identity — no subscription_key needed)
    $migration005Content = $migration005Content `
        -replace "^-- SELECT azure_ai\.set_setting\('azure_openai\.endpoint'", "SELECT azure_ai.set_setting('azure_openai.endpoint'"
    # If AI Services key is available, also configure it
    if ($AI_SERVICES_KEY) {
        $migration005Content = $migration005Content `
            -replace "YOUR-AZURE-OPENAI-KEY", $AI_SERVICES_KEY `
            -replace "^-- SELECT azure_ai\.set_setting\('azure_openai\.subscription_key'", "SELECT azure_ai.set_setting('azure_openai.subscription_key'"
    }
    $tempFile = [System.IO.Path]::GetTempFileName()
    $migration005Content | Set-Content $tempFile -Encoding UTF8
    psql $PGCONN -f $tempFile -v ON_ERROR_STOP=1 2>&1 | Out-Null
    Remove-Item $tempFile
    Log-Ok "005_configure_azure_ai.sql (templated)"

    # Remaining migrations
    Run-Migration "db/migrations/010_schema.sql"
    Run-Migration "db/migrations/020_functions_redact_ingest.sql"
    Run-Migration "db/migrations/030_seed.sql"
    Run-Migration "db/migrations/040_clinical_actions.sql"

    # Migration 050: Cohere rerank (optional)
    if ($COHERE_RERANK -eq "true" -and $COHERE_RERANK_ENDPOINT -and $COHERE_RERANK_KEY) {
        $migration050Content = Get-Content "db/migrations/050_configure_semantic_operators.sql" -Raw
        $migration050Content = $migration050Content `
            -replace "https://ai-gateway-amitmukh.azure-api.net/foundrynextgen-resource/v1/rerank", $COHERE_RERANK_ENDPOINT `
            -replace "86a359eedb16456ca4b161f442f0eff9", $COHERE_RERANK_KEY
        $tempFile050 = [System.IO.Path]::GetTempFileName()
        $migration050Content | Set-Content $tempFile050 -Encoding UTF8
        psql $PGCONN -f $tempFile050 -v ON_ERROR_STOP=1 2>&1 | Out-Null
        Remove-Item $tempFile050
        Log-Ok "050_configure_semantic_operators.sql (templated)"
    } else {
        Log-Skip "050_configure_semantic_operators.sql (COHERE_RERANK not enabled)"
    }

    Run-Migration "db/migrations/060_enhanced_retrieval_reranking.sql"
    Log-Ok "All migrations complete"

    # Verification
    Log-Step "Verification"
    $PATIENT_COUNT = psql $PGCONN -t -A -c "SELECT count(*) FROM patients;" 2>$null
    if ([int]$PATIENT_COUNT -gt 0) {
        Log-Ok "Database seeded: $PATIENT_COUNT patient(s) found"
    } else {
        Log-Warn "No patients found — seed data may not have loaded"
    }

    $env:PGPASSWORD = $null
}

# =============================================================================
# Step 9: Write output env file
# =============================================================================
Log-Step "Writing $ENV_OUTPUT_FILE"

$DB_PASSWORD_ENCODED = [System.Uri]::EscapeDataString($PG_ADMIN_PASSWORD)
$DATABASE_URL = "postgresql://${PG_ADMIN_USER}:${DB_PASSWORD_ENCODED}@${PG_HOST}:5432/${PG_DATABASE_NAME}?sslmode=require"

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
@"
# =============================================================================
# Patient 360 - Pre-deployment Output
# Generated by pre-deploy.ps1 on $timestamp
# =============================================================================

# Database
DATABASE_URL=$DATABASE_URL
DB_HOST=$PG_HOST
DB_NAME=$PG_DATABASE_NAME
DB_USER=$PG_ADMIN_USER
DB_PASSWORD=$PG_ADMIN_PASSWORD

# Azure AI Language (PHI redaction — uses managed identity, no key needed)
AZURE_AI_ENDPOINT=$AI_LANGUAGE_ENDPOINT
AZURE_AI_KEY=

# Azure AI Services (OpenAI-compatible endpoint for DB extensions)
AZURE_AI_SERVICES_ENDPOINT=$AI_SERVICES_ENDPOINT
AZURE_AI_SERVICES_KEY=$AI_SERVICES_KEY

# Azure AI Foundry Project (for Python backend SDK)
AZURE_AI_PROJECT_ENDPOINT=$FOUNDRY_DISCOVERY_URL
AZURE_AI_PROJECT_ID=$FOUNDRY_WORKSPACE_ID

# Model deployments
AZURE_OPENAI_CHAT_DEPLOYMENT=$CHAT_MODEL
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=$EMBEDDING_MODEL

# Resource identifiers (for deploy-azure.ps1)
RESOURCE_GROUP=$RESOURCE_GROUP
LOCATION=$LOCATION
PG_LOCATION=$PG_LOCATION
"@ | Set-Content $ENV_OUTPUT_FILE -Encoding UTF8

Log-Ok "$ENV_OUTPUT_FILE written"

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "=============================================================================" -ForegroundColor Green
Write-Host "  Pre-deployment Complete!" -ForegroundColor Green
Write-Host "=============================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Resource Group:      $RESOURCE_GROUP ($LOCATION)"
Write-Host "  PostgreSQL Server:   $PG_HOST ($PG_LOCATION)"
Write-Host "  PostgreSQL Database: $PG_DATABASE_NAME"
Write-Host "  AI Language:         $AI_LANGUAGE_ENDPOINT"
Write-Host "  AI Services:         $AI_SERVICES_ENDPOINT"
Write-Host "  Foundry Project:     $FOUNDRY_PROJECT_NAME"
Write-Host "  Chat Model:          $CHAT_MODEL"
Write-Host "  Embedding Model:     $EMBEDDING_MODEL"
Write-Host ""
Write-Host "  Output written to:   $ENV_OUTPUT_FILE"
Write-Host "  Auth model:          Managed Identity (Entra ID) for AI Language & AI Services"
Write-Host ""
Write-Host "  Next step:" -ForegroundColor Yellow
Write-Host "    .\deploy-azure.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "=============================================================================" -ForegroundColor Green
