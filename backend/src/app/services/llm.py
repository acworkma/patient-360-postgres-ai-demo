"""
Patient 360 Backend - LLM Service

Generates grounded answers using Azure AI Foundry inference (preferred)
or legacy Azure OpenAI Responses API, with template fallback.
Supports both standard and streaming responses.
"""

import asyncio
import json
import logging
from typing import AsyncGenerator, Optional, Tuple

from app.settings import get_settings
from app.schemas import CopilotSource

logger = logging.getLogger(__name__)


def _create_inference_client(settings):
    """
    Create an OpenAI-compatible chat client via Azure AI Foundry project
    (preferred) or legacy Azure OpenAI endpoint.

    Returns an OpenAI-compatible client that supports .responses.create().
    """
    if settings.has_foundry:
        from azure.ai.projects import AIProjectClient
        from azure.identity import DefaultAzureCredential

        project_client = AIProjectClient.from_connection_string(
            credential=DefaultAzureCredential(),
            conn_str=settings.azure_ai_project_connection_string,
        )
        # get_chat_completions_client returns an OpenAI-compatible client
        return project_client.inference.get_chat_completions_client()

    # Legacy path: direct Azure OpenAI endpoint
    from openai import AzureOpenAI

    endpoint = settings.azure_openai_endpoint.rstrip('/')
    api_version = "2025-03-01-preview"  # Required for Responses API

    if settings.azure_openai_key:
        return AzureOpenAI(
            api_key=settings.azure_openai_key,
            azure_endpoint=endpoint,
            api_version=api_version,
        )
    else:
        from azure.identity import DefaultAzureCredential, get_bearer_token_provider
        credential = DefaultAzureCredential()
        token_provider = get_bearer_token_provider(
            credential, "https://cognitiveservices.azure.com/.default"
        )
        logger.info("Using Entra ID authentication for Azure OpenAI (legacy)")
        return AzureOpenAI(
            azure_ad_token_provider=token_provider,
            azure_endpoint=endpoint,
            api_version=api_version,
        )


# System instructions for clinical copilot
SYSTEM_INSTRUCTIONS = """You are a clinical decision support assistant helping healthcare providers review patient information.

Your role is to:
1. Answer questions accurately based ONLY on the provided context
2. Cite sources using [Source N] format when referencing information
3. Suggest appropriate next clinical actions
4. Be concise but thorough
5. If the context doesn't contain enough information to fully answer, say so

IMPORTANT: 
- Only use information from the provided sources
- Always cite which source(s) you used
- Do not make up information not present in the context
- Use clinical terminology appropriately"""


def _build_context_and_prompt(
    question: str,
    patient_name: str,
    sources: list[CopilotSource]
) -> Tuple[str, str]:
    """
    Build context string and user prompt from sources.
    
    Returns:
        Tuple of (context string, user input prompt)
    """
    # Build context from sources
    context_parts = []
    for i, source in enumerate(sources, 1):
        context_parts.append(
            f"[Source {i} - {source.source_type.upper()}] {source.label}:\n{source.snippet}"
        )
    
    context = "\n\n".join(context_parts) if context_parts else "No relevant context found."
    
    user_input = f"""Patient: {patient_name}

Question: {question}

Relevant Context:
{context}

Please provide:
1. A direct answer to the question based on the context
2. 2-3 recommended next actions for the care team

Format your response as:
ANSWER: [Your answer here with citations]

NEXT ACTIONS:
- [Action 1]
- [Action 2]
- [Action 3]"""
    
    return context, user_input


async def generate_answer(
    question: str,
    patient_name: str,
    sources: list[CopilotSource]
) -> Tuple[str, list[str], Optional[str]]:
    """
    Generate a grounded answer to a clinical question.
    
    Uses Azure OpenAI if configured, otherwise falls back to template-based response.
    
    Returns:
        Tuple of (answer text, list of next actions, model name or None)
    """
    settings = get_settings()
    
    if settings.has_azure_openai:
        return await _generate_with_inference(question, patient_name, sources, settings)
    else:
        return _generate_template_response(question, patient_name, sources)


async def _generate_with_inference(
    question: str,
    patient_name: str,
    sources: list[CopilotSource],
    settings
) -> Tuple[str, list[str], str]:
    """Generate answer using Azure AI Foundry or legacy Azure OpenAI Chat Completions API."""
    
    try:
        client = _create_inference_client(settings)
        
        # Build context and prompt using shared helper
        _, user_input = _build_context_and_prompt(question, patient_name, sources)

        # Use the Chat Completions API (sync call wrapped in asyncio.to_thread)
        def _call_chat_api():
            return client.chat.completions.create(
                model=settings.azure_openai_chat_deployment,
                messages=[
                    {"role": "system", "content": SYSTEM_INSTRUCTIONS},
                    {"role": "user", "content": user_input},
                ],
                max_tokens=1000,
                temperature=0.3
            )
        
        response = await asyncio.to_thread(_call_chat_api)
        
        # Extract text from Chat Completions output
        response_text = response.choices[0].message.content or ""
        
        # Parse the response
        answer, next_actions = _parse_llm_response(response_text)
        
        model_name = settings.azure_openai_chat_deployment
        
        logger.info(f"Generated answer using inference ({model_name})")
        
        return answer, next_actions, model_name
        
    except Exception as e:
        logger.error(f"Inference API error: {str(e)}. Falling back to template response.")
        return _generate_template_response(question, patient_name, sources)


async def generate_answer_stream(
    question: str,
    patient_name: str,
    sources: list[CopilotSource]
) -> AsyncGenerator[str, None]:
    """
    Generate a grounded answer to a clinical question with streaming.
    
    Uses Azure OpenAI Responses API streaming mode.
    Yields Server-Sent Events (SSE) formatted strings.
    
    Event types:
    - source: Source citations
    - delta: Text chunk
    - actions: Next actions (at end)
    - done: Stream complete
    - error: Error occurred
    """
    settings = get_settings()
    
    if not settings.has_azure_openai:
        # Fall back to template-based response (non-streaming)
        answer, next_actions, _ = _generate_template_response(question, patient_name, sources)
        
        # Send sources first
        for source in sources:
            source_data = {
                "source_type": source.source_type,
                "source_id": source.source_id,
                "label": source.label,
                "snippet": source.snippet,
                "score": source.score,
                "metadata": source.metadata
            }
            yield f"event: source\ndata: {json.dumps(source_data)}\n\n"
        
        # Send the full answer as chunks (simulate streaming)
        words = answer.split()
        for i in range(0, len(words), 3):
            chunk = " ".join(words[i:i+3]) + " "
            yield f"event: delta\ndata: {json.dumps({'text': chunk})}\n\n"
            await asyncio.sleep(0.02)  # Small delay for effect
        
        # Send actions
        yield f"event: actions\ndata: {json.dumps({'actions': next_actions})}\n\n"
        yield f"event: done\ndata: {json.dumps({'model': None, 'retrieval_method': 'template'})}\n\n"
        return
    
    try:
        # Stream from inference API (Foundry or legacy Azure OpenAI)
        async for event_str in _stream_with_inference(question, patient_name, sources, settings):
            yield event_str
            
    except Exception as e:
        logger.error(f"Streaming error: {str(e)}")
        yield f"event: error\ndata: {json.dumps({'error': str(e)})}\n\n"


async def _stream_with_inference(
    question: str,
    patient_name: str,
    sources: list[CopilotSource],
    settings
) -> AsyncGenerator[str, None]:
    """Stream answer using Responses API (via Foundry or legacy Azure OpenAI)."""
    
    # Setup client
    client = _create_inference_client(settings)
    
    # First, send all sources
    for source in sources:
        source_data = {
            "source_type": source.source_type,
            "source_id": source.source_id,
            "label": source.label,
            "snippet": source.snippet,
            "score": source.score,
            "metadata": source.metadata
        }
        yield f"event: source\ndata: {json.dumps(source_data)}\n\n"
    
    # Build context and prompt using shared helper
    _, user_input = _build_context_and_prompt(question, patient_name, sources)

    # Call Chat Completions API with streaming
    def _call_streaming_api():
        return client.chat.completions.create(
            model=settings.azure_openai_chat_deployment,
            messages=[
                {"role": "system", "content": SYSTEM_INSTRUCTIONS},
                {"role": "user", "content": user_input},
            ],
            max_tokens=1000,
            temperature=0.3,
            stream=True
        )
    
    # Run the blocking API call in a thread
    stream = await asyncio.to_thread(_call_streaming_api)
    
    # Collect full response for parsing actions at the end
    full_text = ""
    
    # Stream the events
    for chunk in stream:
        if chunk.choices and chunk.choices[0].delta.content:
            delta_text = chunk.choices[0].delta.content
            full_text += delta_text
            yield f"event: delta\ndata: {json.dumps({'text': delta_text})}\n\n"
    
    # Parse the full response to extract next actions
    _, next_actions = _parse_llm_response(full_text)
    
    # Send actions
    yield f"event: actions\ndata: {json.dumps({'actions': next_actions})}\n\n"
    
    # Send done event
    yield f"event: done\ndata: {json.dumps({'model': settings.azure_openai_chat_deployment, 'retrieval_method': 'vector'})}\n\n"
    
    logger.info(f"Streamed answer using inference ({settings.azure_openai_chat_deployment})")


def _parse_llm_response(response_text: str) -> Tuple[str, list[str]]:
    """Parse LLM response into answer and next actions."""
    
    answer = ""
    next_actions = []
    
    # Split by NEXT ACTIONS marker
    if "NEXT ACTIONS:" in response_text:
        parts = response_text.split("NEXT ACTIONS:")
        answer_part = parts[0]
        actions_part = parts[1] if len(parts) > 1 else ""
        
        # Extract answer
        if "ANSWER:" in answer_part:
            answer = answer_part.split("ANSWER:")[1].strip()
        else:
            answer = answer_part.strip()
        
        # Extract actions
        for line in actions_part.strip().split("\n"):
            line = line.strip()
            if line.startswith("-") or line.startswith("•"):
                action = line.lstrip("-•").strip()
                if action:
                    next_actions.append(action)
    else:
        # No structured format, use entire response as answer
        if "ANSWER:" in response_text:
            answer = response_text.split("ANSWER:")[1].strip()
        else:
            answer = response_text.strip()
        
        # Generate default next actions
        next_actions = [
            "Review full clinical context",
            "Document assessment in patient record",
            "Follow up as clinically appropriate"
        ]
    
    return answer, next_actions


def _generate_template_response(
    question: str,
    patient_name: str,
    sources: list[CopilotSource]
) -> Tuple[str, list[str], None]:
    """Generate a template-based response when Azure OpenAI is not available."""
    
    question_lower = question.lower()
    
    # Build source summary
    note_sources = [s for s in sources if s.source_type == "note"]
    lab_sources = [s for s in sources if s.source_type == "lab"]
    med_sources = [s for s in sources if s.source_type == "med"]
    
    # Template responses based on question keywords
    if "last 90 days" in question_lower or "changed" in question_lower or "recent" in question_lower:
        answer = _template_changes_response(patient_name, note_sources, lab_sources, med_sources)
        next_actions = [
            "Review medication changes with patient",
            "Confirm lab trends are in expected direction",
            "Schedule follow-up to assess treatment response"
        ]
    
    elif "lisinopril" in question_lower or "dose" in question_lower:
        answer = _template_medication_response(patient_name, med_sources, lab_sources, note_sources)
        next_actions = [
            "Monitor potassium and kidney function",
            "Assess blood pressure response to dose change",
            "Document rationale in medication history"
        ]
    
    elif "risk" in question_lower or "action" in question_lower:
        answer = _template_risk_response(patient_name, sources)
        next_actions = [
            "Prioritize kidney function monitoring",
            "Ensure diabetes management is optimized",
            "Review cardiovascular risk factors"
        ]
    
    else:
        # Generic response
        answer = _template_generic_response(patient_name, sources)
        next_actions = [
            "Review relevant clinical context",
            "Document findings in patient record",
            "Follow up as clinically indicated"
        ]
    
    return answer, next_actions, None


def _template_changes_response(
    patient_name: str,
    notes: list[CopilotSource],
    labs: list[CopilotSource],
    meds: list[CopilotSource]
) -> str:
    """Generate response about recent changes."""
    
    parts = [f"Based on the available records for {patient_name}, here are the key changes:\n"]
    
    if meds:
        parts.append("**Medication Changes:**")
        for med in meds[:3]:
            parts.append(f"- {med.label}: {med.snippet} [Source: {med.source_type}]")
    
    if labs:
        parts.append("\n**Lab Results:**")
        for lab in labs[:3]:
            parts.append(f"- {lab.label}: {lab.snippet} [Source: {lab.source_type}]")
    
    if notes:
        parts.append("\n**Clinical Notes:**")
        parts.append(f"- {len(notes)} relevant clinical notes found documenting recent care")
    
    if not any([meds, labs, notes]):
        parts.append("Limited information available in the retrieved context.")
    
    return "\n".join(parts)


def _template_medication_response(
    patient_name: str,
    meds: list[CopilotSource],
    labs: list[CopilotSource],
    notes: list[CopilotSource]
) -> str:
    """Generate response about medication changes."""
    
    parts = [f"Regarding medication management for {patient_name}:\n"]
    
    # Look for relevant medication info
    med_info = None
    for med in meds:
        if "lisinopril" in med.label.lower() or "lisinopril" in med.snippet.lower():
            med_info = med
            break
    
    if med_info:
        parts.append(f"**Medication Record:** {med_info.snippet}")
        
        # Check for related labs
        k_lab = next((l for l in labs if "potassium" in l.label.lower() or "k" in l.label.lower()), None)
        cr_lab = next((l for l in labs if "creatinine" in l.label.lower() or "egfr" in l.label.lower()), None)
        
        if k_lab or cr_lab:
            parts.append("\n**Related Lab Values:**")
            if k_lab:
                parts.append(f"- {k_lab.label}: {k_lab.snippet}")
            if cr_lab:
                parts.append(f"- {cr_lab.label}: {cr_lab.snippet}")
        
        # Check for clinical notes
        if notes:
            parts.append(f"\n**Clinical Documentation:** Found {len(notes)} relevant notes discussing this decision")
    else:
        parts.append("Specific medication details found in the following sources:")
        for med in meds[:3]:
            parts.append(f"- {med.label}: {med.snippet}")
    
    return "\n".join(parts)


def _template_risk_response(
    patient_name: str,
    sources: list[CopilotSource]
) -> str:
    """Generate response about risks and recommended actions."""
    
    parts = [f"Risk assessment for {patient_name}:\n"]
    
    parts.append("**Top Clinical Considerations:**")
    parts.append("1. **Kidney Function Monitoring** - CKD Stage 3a requires close monitoring")
    parts.append("2. **Glycemic Control** - A1C trending, continue optimization")
    parts.append("3. **Cardiovascular Risk** - Hypertension and diabetes increase CV risk")
    
    parts.append("\n**Based on Available Sources:**")
    for source in sources[:3]:
        parts.append(f"- [{source.source_type.upper()}] {source.label}")
    
    return "\n".join(parts)


def _template_generic_response(
    patient_name: str,
    sources: list[CopilotSource]
) -> str:
    """Generate a generic response summarizing available information."""
    
    parts = [f"Based on the available records for {patient_name}:\n"]
    
    if sources:
        parts.append("**Relevant Information Found:**")
        for source in sources[:5]:
            parts.append(f"\n[{source.source_type.upper()} - {source.label}]")
            parts.append(source.snippet[:200] + "..." if len(source.snippet) > 200 else source.snippet)
    else:
        parts.append("No relevant information found in the available records.")
        parts.append("Please try rephrasing your question or check that relevant data exists for this patient.")
    
    return "\n".join(parts)
