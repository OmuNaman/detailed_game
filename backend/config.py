"""Application settings loaded from .env file.

The .env file supports two formats:
1. Bare API key on a single line (legacy GDScript format)
2. Standard KEY=VALUE format (e.g., GEMINI_API_KEY=AIza...)
"""

from pathlib import Path

from pydantic_settings import BaseSettings

_ENV_PATH = Path(__file__).resolve().parent.parent / ".env"


def _load_api_key() -> str:
    """Read API key from .env, supporting both bare-key and KEY=VALUE formats."""
    if not _ENV_PATH.exists():
        return ""
    text = _ENV_PATH.read_text(encoding="utf-8").strip()
    if not text:
        return ""
    # If it looks like KEY=VALUE format, let pydantic-settings handle it
    if "=" in text.split("\n")[0]:
        return ""
    # Bare key on first line (legacy GDScript format)
    return text.split("\n")[0].strip()


class Settings(BaseSettings):
    """Backend configuration — all values can be overridden via environment variables."""

    # API keys
    gemini_api_key: str = ""

    # LLM models
    llm_model: str = "gemini-2.5-flash"
    llm_model_lite: str = "gemini-2.5-flash-lite"
    llm_temperature: float = 0.8
    llm_max_tokens: int = 256

    # Embeddings
    embedding_model: str = "gemini-embedding-001"
    embedding_dim: int = 768

    # Storage paths (relative to project root)
    data_dir: str = "data"
    chroma_persist_dir: str = "data/chroma_db"

    model_config = {
        "env_file": str(_ENV_PATH),
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }


# Load settings, falling back to bare-key format if needed
settings = Settings()
if not settings.gemini_api_key:
    _bare_key = _load_api_key()
    if _bare_key:
        settings = Settings(gemini_api_key=_bare_key)
