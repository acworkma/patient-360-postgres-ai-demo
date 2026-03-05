-- ============================================================================
-- Migration 005: Configure Azure AI Extension
-- ============================================================================
-- This script configures the azure_ai extension with Azure AI Language 
-- and Azure OpenAI credentials for PHI redaction and embeddings.
--
-- Authentication: Uses Managed Identity (Entra ID) by default.
-- The PostgreSQL server's system-assigned managed identity must have
-- the "Cognitive Services User" RBAC role on the AI resources.
-- Only the endpoints are configured here; no API keys are needed.
--
-- IMPORTANT: Run this script BEFORE 030_seed.sql
-- ============================================================================

-- ============================================================================
-- AZURE AI LANGUAGE CONFIGURATION (Required for PHI Redaction)
-- ============================================================================
-- Authentication via Managed Identity: only the endpoint is needed.
-- Ensure the PostgreSQL server's managed identity has "Cognitive Services User"
-- role on the AI Language resource.

-- Set the Azure AI Language endpoint
SELECT azure_ai.set_setting('azure_cognitive.endpoint', 'https://YOUR-AI-LANGUAGE-RESOURCE.cognitiveservices.azure.com');

-- NOTE: No subscription_key is set — the azure_ai extension will authenticate
-- using the PostgreSQL server's managed identity automatically.

-- ============================================================================
-- AZURE OPENAI CONFIGURATION (Optional - for Embeddings)
-- ============================================================================
-- For managed identity: only set the endpoint (no subscription_key).
-- For key-based auth: uncomment both the endpoint and subscription_key lines.

-- SELECT azure_ai.set_setting('azure_openai.endpoint', 'https://YOUR-OPENAI-RESOURCE.openai.azure.com');
-- SELECT azure_ai.set_setting('azure_openai.subscription_key', 'YOUR-AZURE-OPENAI-KEY');
-- SELECT azure_ai.set_setting('azure_openai.auth_type', 'managed-identity');

-- ============================================================================
-- VERIFY CONFIGURATION
-- ============================================================================
-- Check that settings were applied correctly

DO $$
DECLARE
    v_endpoint TEXT;
    v_has_key BOOLEAN;
BEGIN
    -- Check Azure Cognitive settings
    v_endpoint := azure_ai.get_setting('azure_cognitive.endpoint');
    v_has_key := azure_ai.get_setting('azure_cognitive.subscription_key') IS NOT NULL 
                 AND azure_ai.get_setting('azure_cognitive.subscription_key') != '';
    
    IF v_endpoint IS NULL OR v_endpoint = '' OR v_endpoint LIKE '%YOUR-%' THEN
        RAISE WARNING 'Azure AI Language endpoint not configured properly!';
        RAISE WARNING 'Please update the endpoint in this script with your actual Azure AI Language endpoint.';
    ELSE
        RAISE NOTICE 'Azure AI Language endpoint configured: %', v_endpoint;
    END IF;
    
    IF NOT v_has_key THEN
        RAISE NOTICE 'Azure AI Language subscription key not set — using managed identity authentication';
    ELSE
        RAISE NOTICE 'Azure AI Language subscription key is set (key-based auth)';
    END IF;
    
    -- Check Azure OpenAI settings (optional)
    v_endpoint := azure_ai.get_setting('azure_openai.endpoint');
    IF v_endpoint IS NOT NULL AND v_endpoint != '' THEN
        RAISE NOTICE 'Azure OpenAI endpoint configured: %', v_endpoint;
    ELSE
        RAISE NOTICE 'Azure OpenAI not configured - embeddings will be skipped';
    END IF;
END $$;

-- ============================================================================
-- TEST PHI REDACTION (Optional)
-- ============================================================================
-- Uncomment to test that PHI redaction is working:

/*
SELECT * FROM azure_cognitive.recognize_pii_entities(
    'Patient John Smith (DOB: 01/15/1960, MRN: 12345678) was seen today. Phone: (555) 123-4567.',
    'en',
    domain => 'phi'
);
*/

-- ============================================================================
-- NOTES
-- ============================================================================
-- 1. Settings are stored at the server level and persist across sessions
-- 2. This configuration uses Managed Identity (Entra ID) by default
-- 3. When subscription_key is not set, the azure_ai extension authenticates
--    using the PostgreSQL server's system-assigned managed identity
-- 4. Ensure "Cognitive Services User" RBAC role is granted to the
--    PostgreSQL managed identity on your Azure AI Language resource
-- 5. For key-based auth (if policy allows), set the subscription_key setting
-- ============================================================================
