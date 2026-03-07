"""LLM client — wraps Gemini API for text generation and embeddings.

Matches gemini_client.gd and embedding_client.gd behavior:
- Generation: system + user message, temp 0.8, max 256 tokens
- Embeddings: gemini-embedding-001, 768 dimensions
"""

from __future__ import annotations

import json
import logging

import httpx

from backend.config import settings

logger = logging.getLogger(__name__)

_GEMINI_API_URL = "https://generativelanguage.googleapis.com/v1beta/models/"


async def generate(
    system_prompt: str,
    user_message: str,
    model: str | None = None,
    max_tokens: int | None = None,
    temperature: float | None = None,
) -> tuple[str, bool]:
    """Generate text via Gemini API. Returns (response_text, success).

    Matches gemini_client.gd generate() behavior.
    """
    if not settings.gemini_api_key:
        logger.warning("No API key — generation disabled")
        return "", False

    model = model or settings.llm_model
    max_tokens = max_tokens or settings.llm_max_tokens
    temperature = temperature if temperature is not None else settings.llm_temperature

    url = f"{_GEMINI_API_URL}{model}:generateContent?key={settings.gemini_api_key}"

    gen_config: dict = {
        "maxOutputTokens": max_tokens,
        "temperature": temperature,
    }
    # Only main model supports thinkingConfig
    if model == settings.llm_model:
        gen_config["thinkingConfig"] = {"thinkingBudget": 0}

    body = {
        "contents": [{"parts": [{"text": user_message}]}],
        "systemInstruction": {"parts": [{"text": system_prompt}]},
        "generationConfig": gen_config,
    }

    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(url, json=body)
            if resp.status_code != 200:
                logger.warning("Gemini API returned %d: %s", resp.status_code, resp.text[:200])
                return "", False

            data = resp.json()
            candidates = data.get("candidates", [])
            if not candidates:
                return "", False

            parts = candidates[0].get("content", {}).get("parts", [])
            if not parts:
                return "", False

            text = parts[0].get("text", "").strip()
            return text, bool(text)

    except Exception as e:
        logger.warning("Gemini API error: %s", e)
        return "", False


async def generate_lite(
    system_prompt: str,
    user_message: str,
    max_tokens: int | None = None,
) -> tuple[str, bool]:
    """Generate with Flash Lite model (cheaper, for analysis tasks)."""
    return await generate(
        system_prompt,
        user_message,
        model=settings.llm_model_lite,
        max_tokens=max_tokens,
    )


async def embed_text(text: str) -> list[float]:
    """Embed text via Gemini embedding API. Returns 768-dim vector or empty list on failure.

    Matches embedding_client.gd embed_text() behavior.
    """
    if not settings.gemini_api_key:
        return []

    url = (
        f"{_GEMINI_API_URL}{settings.embedding_model}"
        f":embedContent?key={settings.gemini_api_key}"
    )
    body = {
        "model": f"models/{settings.embedding_model}",
        "content": {"parts": [{"text": text}]},
        "outputDimensionality": settings.embedding_dim,
    }

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(url, json=body)
            if resp.status_code != 200:
                logger.warning("Embedding API returned %d", resp.status_code)
                return []

            data = resp.json()
            values = data.get("embedding", {}).get("values", [])
            return values if values else []

    except Exception as e:
        logger.warning("Embedding API error: %s", e)
        return []


async def embed_batch(texts: list[str]) -> list[list[float]]:
    """Batch embed multiple texts. Returns list of embeddings (or empty lists on failure).

    Matches embedding_client.gd embed_batch() behavior.
    """
    if not settings.gemini_api_key or not texts:
        return [[] for _ in texts]

    url = (
        f"{_GEMINI_API_URL}{settings.embedding_model}"
        f":batchEmbedContents?key={settings.gemini_api_key}"
    )
    requests = [
        {
            "model": f"models/{settings.embedding_model}",
            "content": {"parts": [{"text": t}]},
            "outputDimensionality": settings.embedding_dim,
        }
        for t in texts
    ]
    body = {"requests": requests}

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(url, json=body)
            if resp.status_code != 200:
                logger.warning("Batch embedding API returned %d", resp.status_code)
                return [[] for _ in texts]

            data = resp.json()
            embeddings_data = data.get("embeddings", [])
            results = []
            for entry in embeddings_data:
                if isinstance(entry, dict):
                    results.append(entry.get("values", []))
                else:
                    results.append([])
            return results

    except Exception as e:
        logger.warning("Batch embedding API error: %s", e)
        return [[] for _ in texts]


def parse_json_response(text: str) -> dict | list | None:
    """Parse JSON from LLM response, stripping markdown fences if present.

    Matches gemini_client.gd parse_json_response().
    """
    cleaned = text.strip()
    if cleaned.startswith("```"):
        first_nl = cleaned.find("\n")
        if first_nl >= 0:
            cleaned = cleaned[first_nl + 1:]
        if cleaned.endswith("```"):
            cleaned = cleaned[:-3].strip()
    try:
        return json.loads(cleaned)
    except (json.JSONDecodeError, ValueError):
        return None
