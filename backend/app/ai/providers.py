"""Bounded async REST adapters. Never log provider payloads or error bodies."""
import json
import re
from urllib.parse import quote

import httpx
from pydantic import ValidationError

from ..config import Settings
from .contracts import ExtractedData
from .prompts import SYSTEM_PROMPT

class ProviderError(Exception):
    def __init__(self, code='provider_error', status=502):
        self.code, self.status = code, status
        super().__init__(code)

# Redact common accidental spoken/typed credentials before sending text upstream.
# This is defense-in-depth, not a guarantee that arbitrary speech contains no secrets.
_SECRET = re.compile(r'(?i)\b(password|passwd|pwd|username|user name|api[_ -]?key|token)\s*(?:is\s+|[:=]\s*|\s+)[^\s,;]+')
_URL = re.compile(r'(?i)\b(?:rtsp|rtsps|https?)://[^\s]+')

def redact(text: str) -> str:
    return _URL.sub('[URL REDACTED]', _SECRET.sub(lambda m: m.group(1) + ' [REDACTED]', text))

class AIProvider:
    def __init__(self, settings: Settings, client: httpx.AsyncClient):
        self.settings, self.client = settings, client

    async def _post(self, url, **kwargs):
        try:
            # Limit decompressed response size as well as the upload size.
            async with self.client.stream('POST', url, timeout=self.settings.provider_timeout_seconds, **kwargs) as response:
                if response.status_code == 429:
                    raise ProviderError('provider_rate_limited', 503)
                if response.status_code >= 400:
                    raise ProviderError('provider_unavailable' if response.status_code >= 500 else 'provider_rejected', 502)
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body.extend(chunk)
                    if len(body) > 2 * 1024 * 1024:
                        raise ProviderError('provider_response_too_large')
                return json.loads(body)
        except httpx.TimeoutException as exc:
            raise ProviderError('provider_timeout', 504) from exc
        except httpx.HTTPError as exc:
            raise ProviderError('provider_unreachable', 503) from exc
        except (ValueError, UnicodeError) as exc:
            raise ProviderError('invalid_provider_response') from exc

    async def extract(self, transcript: str, context: ExtractedData | None) -> ExtractedData:
        payload = json.dumps({'transcript': redact(transcript),
                              'context': _sanitize(context.model_dump(mode='json')) if context else None}, ensure_ascii=False)
        # Pydantic schema in prompt works across both providers, including models
        # without support for every JSON-Schema keyword in native structured output.
        prompt = SYSTEM_PROMPT + '\nJSON SCHEMA:\n' + json.dumps(ExtractedData.model_json_schema())
        if self.settings.ai_provider == 'gemini':
            if not self.settings.gemini_api_key:
                raise ProviderError('gemini_not_configured', 503)
            result = await self._post(
                'https://generativelanguage.googleapis.com/v1beta/models/' + quote(self.settings.gemini_model, safe='') + ':generateContent',
                headers={'x-goog-api-key': self.settings.gemini_api_key.get_secret_value()},
                json={'systemInstruction': {'parts': [{'text': prompt}]},
                      'contents': [{'role':'user', 'parts':[{'text':payload}]}],
                      'generationConfig': {'temperature':0, 'responseMimeType':'application/json', 'maxOutputTokens':16384, 'thinkingConfig':{'thinkingBudget':0}}})
            try:
                candidate = result['candidates'][0]
                if candidate.get('finishReason') != 'STOP':
                    raise ProviderError('incomplete_provider_output')
                output = ''.join(p['text'] for p in candidate['content']['parts'] if 'text' in p and not p.get('thought'))
            except (KeyError, IndexError, TypeError, AttributeError) as exc:
                raise ProviderError('invalid_provider_response') from exc
        else:
            if not self.settings.groq_api_key:
                raise ProviderError('groq_not_configured', 503)
            result = await self._post('https://api.groq.com/openai/v1/chat/completions',
                headers={'Authorization': 'Bearer ' + self.settings.groq_api_key.get_secret_value()},
                json={'model':self.settings.groq_model, 'temperature':0, 'max_tokens':12000,
                      'response_format':{'type':'json_object'},
                      'messages':[{'role':'system','content':prompt}, {'role':'user','content':payload}]})
            try:
                choice = result['choices'][0]
                if choice.get('finish_reason') != 'stop':
                    raise ProviderError('incomplete_provider_output')
                output = choice['message']['content']
            except (KeyError, IndexError, TypeError, AttributeError) as exc:
                raise ProviderError('invalid_provider_response') from exc
        try:
            # Validation rejects extra keys, malformed data and dangling topology.
            # Redact known credential patterns in free text before returning proposals.
            parsed = ExtractedData.model_validate_json(output)
            return ExtractedData.model_validate(_sanitize(parsed.model_dump(mode='json')))
        except (ValidationError, ValueError, TypeError) as exc:
            raise ProviderError('invalid_extracted_data') from exc

    async def transcribe(self, audio: bytes, mime: str, language: str) -> str:
        if not self.settings.groq_api_key:
            raise ProviderError('audio_transcription_not_configured', 503)
        extension = {'audio/wav':'wav','audio/x-wav':'wav','audio/mpeg':'mp3','audio/mp4':'m4a','audio/webm':'webm','audio/ogg':'ogg','audio/flac':'flac'}[mime]
        data = {'model':self.settings.groq_whisper_model, 'response_format':'json', 'temperature':'0',
                'prompt':'Smartiva CCTV site briefing. Tamil, Tanglish and English. NVR, DVR, Dahua, CP Plus, Hikvision, PoE, UPS.'}
        if language != 'auto':
            data['language'] = language
        result = await self._post('https://api.groq.com/openai/v1/audio/transcriptions',
            headers={'Authorization':'Bearer ' + self.settings.groq_api_key.get_secret_value()},
            data=data, files={'file':('briefing.' + extension, audio, mime)})
        transcript = result.get('text') if isinstance(result, dict) else None
        if not isinstance(transcript, str) or not transcript.strip() or len(transcript) > 30000:
            raise ProviderError('invalid_transcript')
        return redact(transcript.strip())


def _sanitize(value):
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, list):
        return [_sanitize(v) for v in value]
    if isinstance(value, dict):
        return {k: _sanitize(v) for k, v in value.items()}
    return value
