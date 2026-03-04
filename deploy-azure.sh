#!/bin/bash
# =============================================================================
# Patient 360 - Azure Deployment Script
# =============================================================================
# This script deploys:
#   - Backend → Azure Container Apps
#   - Frontend → Azure Web Apps (Container)
#   - Uses Azure Container Registry for images
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Source pre-deploy output if available (auto-fills config below)
# -----------------------------------------------------------------------------
if [[ -f "pre-deploy-output.env" ]]; then
    echo "📂 Loading configuration from pre-deploy-output.env"
    set -a
    # shellcheck disable=SC1091
    source pre-deploy-output.env
    set +a
fi

# -----------------------------------------------------------------------------
# Configuration - UPDATE THESE VALUES (or run pre-deploy.sh first)
# -----------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-patient360-rg}"
LOCATION="${LOCATION:-eastus2}"
ACR_NAME="${ACR_NAME:-patient360acr}"  # Must be globally unique, lowercase, no dashes

# Container Apps
CONTAINER_ENV_NAME="${CONTAINER_ENV_NAME:-patient360-env}"
BACKEND_APP_NAME="${BACKEND_APP_NAME:-patient360-backend}"

# Web App
APP_SERVICE_PLAN="${APP_SERVICE_PLAN:-patient360-plan}"
FRONTEND_APP_NAME="${FRONTEND_APP_NAME:-patient360-frontend}"  # Must be globally unique

# Database (set by pre-deploy.sh or override here)
DB_HOST="${DB_HOST:-your-server.postgres.database.azure.com}"
DB_NAME="${DB_NAME:-patient360}"
DB_USER="${DB_USER:-pgadmin}"
DB_PASSWORD="${DB_PASSWORD:-your-password}"

# Azure AI Services (set by pre-deploy.sh or override here)
AZURE_AI_ENDPOINT="${AZURE_AI_ENDPOINT:-https://your-ai.cognitiveservices.azure.com}"
AZURE_AI_KEY="${AZURE_AI_KEY:-your-azure-ai-key}"

# Azure AI Foundry / AI Services (set by pre-deploy.sh or override here)
AZURE_AI_SERVICES_ENDPOINT="${AZURE_AI_SERVICES_ENDPOINT:-}"
AZURE_AI_SERVICES_KEY="${AZURE_AI_SERVICES_KEY:-}"
AZURE_AI_PROJECT_ENDPOINT="${AZURE_AI_PROJECT_ENDPOINT:-}"

# Model deployments
AZURE_OPENAI_CHAT_DEPLOYMENT="${AZURE_OPENAI_CHAT_DEPLOYMENT:-gpt-4o}"
AZURE_OPENAI_EMBEDDING_DEPLOYMENT="${AZURE_OPENAI_EMBEDDING_DEPLOYMENT:-text-embedding-3-small}"

# -----------------------------------------------------------------------------
# Step 1: Create Resource Group
# -----------------------------------------------------------------------------
echo "📦 Creating Resource Group..."
az group create --name $RESOURCE_GROUP --location $LOCATION

# -----------------------------------------------------------------------------
# Step 2: Create Azure Container Registry
# -----------------------------------------------------------------------------
echo "🐳 Creating Azure Container Registry..."
az acr create \
    --name $ACR_NAME \
    --resource-group $RESOURCE_GROUP \
    --sku Basic \
    --admin-enabled true

# Get ACR credentials
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --query loginServer -o tsv)
ACR_USERNAME=$(az acr credential show --name $ACR_NAME --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --query "passwords[0].value" -o tsv)

echo "✅ ACR Created: $ACR_LOGIN_SERVER"

# Login to ACR
az acr login --name $ACR_NAME

# -----------------------------------------------------------------------------
# Step 3: Build and Push Backend Image
# -----------------------------------------------------------------------------
echo "🔨 Building Backend Image..."
cd backend
docker build -t $ACR_LOGIN_SERVER/patient360-backend:latest .
docker push $ACR_LOGIN_SERVER/patient360-backend:latest
cd ..

echo "✅ Backend image pushed to ACR"

# -----------------------------------------------------------------------------
# Step 4: Build and Push Frontend Image
# -----------------------------------------------------------------------------
echo "🔨 Building Frontend Image..."

# Get the backend URL (will be set after backend deployment)
# For now, use a placeholder - we'll update after backend is deployed
cd frontend
docker build \
    --build-arg NEXT_PUBLIC_API_BASE_URL="https://${BACKEND_APP_NAME}.azurecontainerapps.io" \
    -t $ACR_LOGIN_SERVER/patient360-frontend:latest .
docker push $ACR_LOGIN_SERVER/patient360-frontend:latest
cd ..

echo "✅ Frontend image pushed to ACR"

# -----------------------------------------------------------------------------
# Step 5: Create Container Apps Environment
# -----------------------------------------------------------------------------
echo "🌐 Creating Container Apps Environment..."
az containerapp env create \
    --name $CONTAINER_ENV_NAME \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION

# -----------------------------------------------------------------------------
# Step 6: Deploy Backend to Container Apps
# -----------------------------------------------------------------------------
echo "🚀 Deploying Backend to Container Apps..."

# Create the connection string
DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:5432/${DB_NAME}?sslmode=require"

az containerapp create \
    --name $BACKEND_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --environment $CONTAINER_ENV_NAME \
    --image $ACR_LOGIN_SERVER/patient360-backend:latest \
    --target-port 8000 \
    --ingress external \
    --min-replicas 1 \
    --max-replicas 3 \
    --cpu 0.5 \
    --memory 1.0Gi \
    --registry-server $ACR_LOGIN_SERVER \
    --registry-username $ACR_USERNAME \
    --registry-password $ACR_PASSWORD \
    --env-vars \
        DATABASE_URL="$DATABASE_URL" \
        AZURE_AI_ENDPOINT="$AZURE_AI_ENDPOINT" \
        AZURE_AI_KEY="$AZURE_AI_KEY" \
        AZURE_AI_PROJECT_CONNECTION_STRING="$AZURE_AI_PROJECT_ENDPOINT" \
        AZURE_OPENAI_ENDPOINT="$AZURE_AI_SERVICES_ENDPOINT" \
        AZURE_OPENAI_CHAT_DEPLOYMENT="$AZURE_OPENAI_CHAT_DEPLOYMENT" \
        AZURE_OPENAI_EMBEDDING_DEPLOYMENT="$AZURE_OPENAI_EMBEDDING_DEPLOYMENT" \
        CORS_ORIGINS="https://${FRONTEND_APP_NAME}.azurewebsites.net,http://localhost:3000" \
        DEMO_ALLOW_RAW="false"

# Get backend URL
BACKEND_URL=$(az containerapp show \
    --name $BACKEND_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --query properties.configuration.ingress.fqdn -o tsv)

echo "✅ Backend deployed: https://$BACKEND_URL"

# -----------------------------------------------------------------------------
# Step 7: Rebuild Frontend with Correct Backend URL
# -----------------------------------------------------------------------------
echo "🔄 Rebuilding Frontend with Backend URL..."
cd frontend
docker build \
    --build-arg NEXT_PUBLIC_API_BASE_URL="https://$BACKEND_URL" \
    -t $ACR_LOGIN_SERVER/patient360-frontend:latest .
docker push $ACR_LOGIN_SERVER/patient360-frontend:latest
cd ..

# -----------------------------------------------------------------------------
# Step 8: Create App Service Plan for Frontend
# -----------------------------------------------------------------------------
echo "📋 Creating App Service Plan..."
az appservice plan create \
    --name $APP_SERVICE_PLAN \
    --resource-group $RESOURCE_GROUP \
    --is-linux \
    --sku B1

# -----------------------------------------------------------------------------
# Step 9: Deploy Frontend to Azure Web Apps
# -----------------------------------------------------------------------------
echo "🚀 Deploying Frontend to Azure Web Apps..."
az webapp create \
    --name $FRONTEND_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --plan $APP_SERVICE_PLAN \
    --deployment-container-image-name $ACR_LOGIN_SERVER/patient360-frontend:latest

# Configure container settings
az webapp config container set \
    --name $FRONTEND_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --docker-custom-image-name $ACR_LOGIN_SERVER/patient360-frontend:latest \
    --docker-registry-server-url https://$ACR_LOGIN_SERVER \
    --docker-registry-server-user $ACR_USERNAME \
    --docker-registry-server-password $ACR_PASSWORD

# Set app settings
az webapp config appsettings set \
    --name $FRONTEND_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --settings \
        WEBSITES_PORT=3000 \
        NEXT_PUBLIC_API_BASE_URL="https://$BACKEND_URL"

# Enable logging
az webapp log config \
    --name $FRONTEND_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --docker-container-logging filesystem

# Restart to pick up changes
az webapp restart --name $FRONTEND_APP_NAME --resource-group $RESOURCE_GROUP

FRONTEND_URL=$(az webapp show \
    --name $FRONTEND_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --query defaultHostName -o tsv)

echo "✅ Frontend deployed: https://$FRONTEND_URL"

# -----------------------------------------------------------------------------
# Step 10: Update Backend CORS with Frontend URL
# -----------------------------------------------------------------------------
echo "🔧 Updating Backend CORS settings..."
az containerapp update \
    --name $BACKEND_APP_NAME \
    --resource-group $RESOURCE_GROUP \
    --set-env-vars \
        CORS_ORIGINS="https://$FRONTEND_URL,http://localhost:3000"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================================================="
echo "🎉 Deployment Complete!"
echo "============================================================================="
echo ""
echo "Frontend URL:  https://$FRONTEND_URL"
echo "Backend URL:   https://$BACKEND_URL"
echo "Backend Docs:  https://$BACKEND_URL/docs"
echo ""
echo "Resources created in resource group: $RESOURCE_GROUP"
echo "  - Azure Container Registry: $ACR_NAME"
echo "  - Container Apps Environment: $CONTAINER_ENV_NAME"
echo "  - Container App (Backend): $BACKEND_APP_NAME"
echo "  - App Service Plan: $APP_SERVICE_PLAN"
echo "  - Web App (Frontend): $FRONTEND_APP_NAME"
echo ""
echo "============================================================================="
