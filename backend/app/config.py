from typing import Literal
from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix='SMARTIVA_', env_file='.env', extra='ignore')
    api_token: SecretStr = Field(min_length=32)
    database_url: SecretStr | None = None
    audio_storage_path: str = './private-audio'
    ai_provider: Literal['gemini','groq'] = 'gemini'
    gemini_api_key: SecretStr | None = None
    groq_api_key: SecretStr | None = None
    gemini_model: str = 'gemini-2.5-flash'
    groq_model: str = 'llama-3.3-70b-versatile'
    groq_whisper_model: str = 'whisper-large-v3'
    provider_timeout_seconds: float = Field(default=45, gt=0, le=120)
    briefing_timeout_seconds: float = Field(default=100, gt=0, le=240)
    max_request_bytes: int = Field(default=12 * 1024 * 1024, ge=1024, le=32 * 1024 * 1024)
    max_audio_bytes: int = Field(default=10 * 1024 * 1024, ge=1024, le=25 * 1024 * 1024)
    max_concurrent_briefings: int = Field(default=4, ge=1, le=100)
