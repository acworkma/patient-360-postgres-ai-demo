# =============================================================================
# Patient 360 - Azure Deployment Script (PowerShell)
# =============================================================================
# This script deploys:
#   - Backend → Azure Container Apps
#   - Frontend → Azure Web Apps (Container)
#   - Uses Azure Container Registry for images
# =============================================================================

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Source pre-deploy output if available (auto-fills config below)
# -----------------------------------------------------------------------------
if (Test-Path "pre-deploy-output.env") {
    Write-Host "📂 Loading configuration from pre-deploy-output.env" -ForegroundColor Cyan
    Get-Content "pre-deploy-output.env" | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
        }
    }
}

# -----------------------------------------------------------------------------
# Configuration - UPDATE THESE VALUES (or run pre-deploy.ps1 first)
# -----------------------------------------------------------------------------
$RESOURCE_GROUP = if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "patient360-rg" }
$LOCATION = if ($env:LOCATION) { $env:LOCATION } else { "eastus2" }
$ACR_NAME = if ($env:ACR_NAME) { $env:ACR_NAME } else { "patient360acr" }  # Must be globally unique, lowercase, no dashes

# Container Apps
$CONTAINER_ENV_NAME = if ($env:CONTAINER_ENV_NAME) { $env:CONTAINER_ENV_NAME } else { "patient360-env" }
$BACKEND_APP_NAME = if ($env:BACKEND_APP_NAME) { $env:BACKEND_APP_NAME } else { "patient360-backend" }

# Web App
$APP_SERVICE_PLAN = if ($env:APP_SERVICE_PLAN) { $env:APP_SERVICE_PLAN } else { "patient360-plan" }
$FRONTEND_APP_NAME = if ($env:FRONTEND_APP_NAME) { $env:FRONTEND_APP_NAME } else { "patient360-frontend" }  # Must be globally unique

# Database (set by pre-deploy.ps1 or override here)
$DB_HOST = if ($env:DB_HOST) { $env:DB_HOST } else { "your-db.postgres.database.azure.com" }
$DB_NAME = if ($env:DB_NAME) { $env:DB_NAME } else { "patient360" }
$DB_USER = if ($env:DB_USER) { $env:DB_USER } else { "pgadmin" }
$DB_PASSWORD = if ($env:DB_PASSWORD) { $env:DB_PASSWORD } else { throw "Set `$env:DB_PASSWORD before running" }

# Azure AI Language
$AZURE_AI_ENDPOINT = if ($env:AZURE_AI_ENDPOINT) { $env:AZURE_AI_ENDPOINT } else { "https://your-language-service.cognitiveservices.azure.com" }
$AZURE_AI_KEY = if ($env:AZURE_AI_KEY) { $env:AZURE_AI_KEY } else { throw "Set `$env:AZURE_AI_KEY before running" }

# Azure AI Foundry / AI Services (set by pre-deploy.ps1 or override here)
$AZURE_AI_SERVICES_ENDPOINT = if ($env:AZURE_AI_SERVICES_ENDPOINT) { $env:AZURE_AI_SERVICES_ENDPOINT } else { "" }
$AZURE_AI_SERVICES_KEY = if ($env:AZURE_AI_SERVICES_KEY) { $env:AZURE_AI_SERVICES_KEY } else { "" }
$AZURE_AI_PROJECT_ENDPOINT = if ($env:AZURE_AI_PROJECT_ENDPOINT) { $env:AZURE_AI_PROJECT_ENDPOINT } else { "" }

# Model deployments
$AZURE_OPENAI_CHAT_DEPLOYMENT = if ($env:AZURE_OPENAI_CHAT_DEPLOYMENT) { $env:AZURE_OPENAI_CHAT_DEPLOYMENT } else { "gpt-4o" }
$AZURE_OPENAI_EMBEDDING_DEPLOYMENT = if ($env:AZURE_OPENAI_EMBEDDING_DEPLOYMENT) { $env:AZURE_OPENAI_EMBEDDING_DEPLOYMENT } else { "text-embedding-3-small" }

# -----------------------------------------------------------------------------
# Step 1: Create Resource Group
# -----------------------------------------------------------------------------
Write-Host "📦 Creating Resource Group..." -ForegroundColor Cyan
az group create --name $RESOURCE_GROUP --location $LOCATION

# -----------------------------------------------------------------------------
# Step 2: Create Azure Container Registry
# -----------------------------------------------------------------------------
Write-Host "🐳 Creating Azure Container Registry..." -ForegroundColor Cyan
az acr create `
    --name $ACR_NAME `
    --resource-group $RESOURCE_GROUP `
    --sku Basic `
    --admin-enabled true

# Get ACR credentials
$ACR_LOGIN_SERVER = az acr show --name $ACR_NAME --query loginServer -o tsv
$ACR_USERNAME = az acr credential show --name $ACR_NAME --query username -o tsv
$ACR_PASSWORD = az acr credential show --name $ACR_NAME --query "passwords[0].value" -o tsv

Write-Host "✅ ACR Created: $ACR_LOGIN_SERVER" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Step 3: Build and Push Backend Image (using ACR Tasks - no Docker required)
# -----------------------------------------------------------------------------
Write-Host "🔨 Building Backend Image in Azure..." -ForegroundColor Cyan
az acr build `
    --registry $ACR_NAME `
    --resource-group $RESOURCE_GROUP `
    --image patient360-backend:latest `
    --file backend/Dockerfile `
    backend/

Write-Host "✅ Backend image built and pushed to ACR" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Step 4: Build and Push Frontend Image (using ACR Tasks - no Docker required)
# -----------------------------------------------------------------------------
Write-Host "🔨 Building Frontend Image in Azure..." -ForegroundColor Cyan
az acr build `
    --registry $ACR_NAME `
    --resource-group $RESOURCE_GROUP `
    --image patient360-frontend:latest `
    --file frontend/Dockerfile `
    --build-arg NEXT_PUBLIC_API_BASE_URL="https://$BACKEND_APP_NAME.azurecontainerapps.io" `
    frontend/

Write-Host "✅ Frontend image built and pushed to ACR" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Step 5: Create Container Apps Environment
# -----------------------------------------------------------------------------
Write-Host "🌐 Creating Container Apps Environment..." -ForegroundColor Cyan
az containerapp env create `
    --name $CONTAINER_ENV_NAME `
    --resource-group $RESOURCE_GROUP `
    --location $LOCATION

# -----------------------------------------------------------------------------
# Step 6: Deploy Backend to Container Apps
# -----------------------------------------------------------------------------
Write-Host "🚀 Deploying Backend to Container Apps..." -ForegroundColor Cyan

# URL encode the password if it contains special characters
$DB_PASSWORD_ENCODED = [System.Uri]::EscapeDataString($DB_PASSWORD)
$DATABASE_URL = "postgresql://${DB_USER}:${DB_PASSWORD_ENCODED}@${DB_HOST}:5432/${DB_NAME}?sslmode=require"

az containerapp create `
    --name $BACKEND_APP_NAME `
    --resource-group $RESOURCE_GROUP `
    --environment $CONTAINER_ENV_NAME `
    --image "$ACR_LOGIN_SERVER/patient360-backend:latest" `
    --target-port 8000 `
    --ingress external `
    --min-replicas 1 `
    --max-replicas 3 `
    --cpu 0.5 `
    --memory 1.0Gi `
    --registry-server $ACR_LOGIN_SERVER `
    --registry-username $ACR_USERNAME `
    --registry-password $ACR_PASSWORD `
    --env-vars `
        "DATABASE_URL=$DATABASE_URL" `
        "AZURE_AI_ENDPOINT=$AZURE_AI_ENDPOINT" `
        "AZURE_AI_KEY=$AZURE_AI_KEY" `
        "AZURE_AI_PROJECT_CONNECTION_STRING=$AZURE_AI_PROJECT_ENDPOINT" `
        "AZURE_OPENAI_ENDPOINT=$AZURE_AI_SERVICES_ENDPOINT" `
        "AZURE_OPENAI_CHAT_DEPLOYMENT=$AZURE_OPENAI_CHAT_DEPLOYMENT" `
        "AZURE_OPENAI_EMBEDDING_DEPLOYMENT=$AZURE_OPENAI_EMBEDDING_DEPLOYMENT" `
        "CORS_ORIGINS=https://${FRONTEND_APP_NAME}.azurewebsites.net,http://localhost:3000" `
        "DEMO_ALLOW_RAW=false"

# Get backend URL
$BACKEND_URL = az containerapp show `
    --name $BACKEND_APP_NAME `
    --resource-group $RESOURCE_GROUP `
    --query properties.configuration.ingress.fqdn -o tsv

Write-Host "✅ Backend deployed: https://$BACKEND_URL" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Step 7: Rebuild Frontend with Correct Backend URL (using ACR Tasks)
# -----------------------------------------------------------------------------
Write-Host "🔄 Rebuilding Frontend with Backend URL in Azure..." -ForegroundColor Cyan
az acr build `
    --registry $ACR_NAME `
    --resource-group $RESOURCE_GROUP `
    --image patient360-frontend:latest `
    --file frontend/Dockerfile `
    --build-arg NEXT_PUBLIC_API_BASE_URL="https://$BACKEND_URL" `
    frontend/

# -----------------------------------------------------------------------------
# Step 8: Create App Service Plan for Frontend
# -----------------------------------------------------------------------------
Write-Host "📋 Creating App Service Plan..." -ForegroundColor Cyan
az appservice plan create `
    --name $APP_SERVICE_PLAN `
    --resource-group $RESOURCE_GROUP `
    --is-linux `
    --sku B1

# -----------------------------------------------------------------------------
# Step 9: Deploy Frontend to Azure Web Apps
# -----------------------------------------------------------------------------
Write-Host "🚀 Deploying Frontend to Azure Web Apps..." -ForegroundColor Cyan
az webapp create `
    --name $FRONTEND_APP_NAME `
    --resource-group $RESOURCE_GROUP `
    --plan $APP_SERVICE_PLAN `
    --deployment-container-image-name "$ACR_LOGIN_SERVER/patient360-frontend:latest"

# Configure container settings
az webapp config container set `
    --name $FRONTEND_APP_NAME `
    --resource-group $RESOURCE_GROUP `
    --docker-custom-image-name "$ACR_LOGIN_SERVER/patient360-frontend:latest" `
    --docker-registry-server-url "https://$ACR_LOGIN_SERVER" `
    --docker-registry-server-user $ACR_USERNAME `
    --docker-registry-server-password $ACR_PASSWORD

# Set app settings
az webapp config appsettings set `
    --name $FRONTEND_APP_NAME `
    --resource-group $RESOURCE_GROUP `
    --settings `
        WEBSITES_PORT=3000 `
        NEXT_PUBLIC_API_BASE_URL="https://$BACKEND_URL"

# Enable logging
az webapp log config `
    --name $FRONTEND_APP_NAME `
    --resource-group $RESOURCE_GROUP `
    --docker-container-logging filesystem

# Restart to pick up changes
az webapp restart --name $FRONTEND_APP_NAME --resource-group $RESOURCE_GROUP

$FRONTEND_URL = az webapp show `
    --name $FRONTEND_APP_NAME `
    --resource-group $RESOURCE_GROUP `
    --query defaultHostName -o tsv

Write-Host "✅ Frontend deployed: https://$FRONTEND_URL" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Step 10: Update Backend CORS with Frontend URL
# -----------------------------------------------------------------------------
Write-Host "🔧 Updating Backend CORS settings..." -ForegroundColor Cyan
az containerapp update `
    --name $BACKEND_APP_NAME `
    --resource-group $RESOURCE_GROUP `
    --set-env-vars `
        "CORS_ORIGINS=https://$FRONTEND_URL,http://localhost:3000"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================================================" -ForegroundColor Green
Write-Host "🎉 Deployment Complete!" -ForegroundColor Green
Write-Host "=============================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Frontend URL:  https://$FRONTEND_URL" -ForegroundColor Yellow
Write-Host "Backend URL:   https://$BACKEND_URL" -ForegroundColor Yellow
Write-Host "Backend Docs:  https://$BACKEND_URL/docs" -ForegroundColor Yellow
Write-Host ""
Write-Host "Resources created in resource group: $RESOURCE_GROUP"
Write-Host "  - Azure Container Registry: $ACR_NAME"
Write-Host "  - Container Apps Environment: $CONTAINER_ENV_NAME"
Write-Host "  - Container App (Backend): $BACKEND_APP_NAME"
Write-Host "  - App Service Plan: $APP_SERVICE_PLAN"
Write-Host "  - Web App (Frontend): $FRONTEND_APP_NAME"
Write-Host ""
Write-Host "=============================================================================" -ForegroundColor Green

