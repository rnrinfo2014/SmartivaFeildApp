"""Smartiva Step 2: authenticated, stateless AI briefing API."""
import asyncio
from contextlib import asynccontextmanager
import json
import secrets

import httpx
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from sqlalchemy.exc import OperationalError, IntegrityError
from fastapi.concurrency import run_in_threadpool
from .sync.api import router as sync_router
from .sync.service import authenticate as device_auth, authorize as site_auth
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import ValidationError
from starlette.datastructures import UploadFile
from starlette.exceptions import HTTPException as StarletteHTTPException

from .ai.contracts import BriefingRequest, BriefingResponse
from .ai.probing import probe_site
from .ai.providers import AIProvider, ProviderError, redact
from .config import Settings
from .readiness import deployment_ready

MIMES = {'audio/wav', 'audio/x-wav', 'audio/mpeg', 'audio/mp4', 'audio/webm', 'audio/ogg', 'audio/flac'}
bearer = HTTPBearer(auto_error=False)

class BodyLimit:
    """Bound request bodies including chunked uploads before multipart parsing."""
    def __init__(self, app, limit):
        self.app, self.limit = app, limit

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope, receive, send)
        chunks, size = [], 0
        while True:
            message = await receive()
            if message['type'] == 'http.disconnect':
                return
            chunk = message.get('body', b'')
            size += len(chunk)
            if size > self.limit:
                return await JSONResponse(status_code=413, content={'detail':'request_too_large'})(scope, receive, send)
            chunks.append(chunk)
            if not message.get('more_body', False):
                break
        delivered = False
        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {'type':'http.request', 'body':b''.join(chunks), 'more_body':False}
            return await receive()
        await self.app(scope, replay, send)


def create_app(settings: Settings | None = None, provider: AIProvider | None = None) -> FastAPI:
    settings = settings or Settings()

    engine=create_engine(settings.database_url.get_secret_value(),pool_pre_ping=True,
                         connect_args={'connect_timeout':5},pool_timeout=5) if settings.database_url else None
    if engine is not None and engine.dialect.name != "postgresql":
        raise ValueError("Inventory sync requires PostgreSQL")

    @asynccontextmanager
    async def lifespan(app):
        # Shared bounded connection pool, TLS verification and injected proxy preserved.
        async with httpx.AsyncClient(limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
                                     follow_redirects=False) as client:
            app.state.provider = provider or AIProvider(settings, client)
            yield
        if engine is not None: engine.dispose()

    app = FastAPI(title='Smartiva FieldOps API', version='0.5.0', lifespan=lifespan)
    app.state.db_engine=engine
    app.state.settings=settings
    app.include_router(sync_router)
    app.add_middleware(BodyLimit, limit=settings.max_request_bytes)
    slots = asyncio.Semaphore(settings.max_concurrent_briefings)

    async def authenticate(request: Request, credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if credentials is None:
            raise HTTPException(401,'unauthorized',headers={'WWW-Authenticate':'Bearer'})
        if secrets.compare_digest(credentials.credentials.encode(),settings.api_token.get_secret_value().encode()):
            request.state.actor=None # Internal AI-only service token never authorizes sync.
            return
        if engine is None: raise HTTPException(401,'unauthorized')
        def load():
            with Session(engine) as db: return device_auth(db,credentials.credentials)
        request.state.actor=await run_in_threadpool(load)

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request, exc):
        # FastAPI's default validation response may echo transcripts or secrets.
        return JSONResponse(status_code=422, content={'detail':'invalid_request'})

    @app.exception_handler(OperationalError)
    async def database_unavailable(request,exc):
        return JSONResponse(status_code=503,content={'detail':'database_temporarily_unavailable'})

    @app.exception_handler(IntegrityError)
    async def database_constraint(request,exc):
        return JSONResponse(status_code=409,content={'detail':'inventory_constraint_conflict'})

    @app.get('/healthz')
    async def health():
        return {'status':'ok'}

    @app.get('/readyz', include_in_schema=False)
    async def ready():
        # Readiness checks configuration/storage/database, not paid provider calls.
        if not await run_in_threadpool(deployment_ready, settings, engine):
            return JSONResponse(status_code=503, content={'status':'not_ready'})
        return {'status':'ready'}

    @app.post('/api/v1/ai/site-briefing', response_model=BriefingResponse, dependencies=[Depends(authenticate)],
              openapi_extra={'requestBody': {'required':True, 'content':{
                  'application/json':{'schema':BriefingRequest.model_json_schema(ref_template='#/components/schemas/{model}')},
                  'multipart/form-data':{'schema':{'type':'object','required':['audio'], 'properties':{
                      'audio':{'type':'string','format':'binary'},
                      'metadata':{'type':'string','description':'JSON containing optional language, site_id and context; no text.'}}}}
              }}})
    async def briefing(request: Request):
        content_type = request.headers.get('content-type', '').split(';', 1)[0].lower()
        audio = None
        mime = None
        if content_type == 'application/json':
            try:
                payload = BriefingRequest.model_validate_json(await request.body())
            except (ValidationError, ValueError):
                raise HTTPException(422, 'invalid_request') from None
        elif content_type == 'multipart/form-data':
            try:
                async with request.form(max_files=1, max_fields=1, max_part_size=1024*1024) as form:
                    if set(form.keys()) - {'metadata','audio'} or len(form.getlist('audio')) != 1 or len(form.getlist('metadata')) > 1:
                        raise HTTPException(422, 'invalid_multipart_fields')
                    upload = form.get('audio')
                    metadata = form.get('metadata', '{}')
                    if not isinstance(upload, UploadFile) or not isinstance(metadata, str):
                        raise HTTPException(422, 'audio_required')
                    meta = json.loads(metadata)
                    if not isinstance(meta, dict) or 'text' in meta:
                        raise HTTPException(422, 'invalid_audio_metadata')
                    payload = BriefingRequest.model_validate({'text':'audio briefing', **meta})
                    mime = (upload.content_type or '').split(';', 1)[0].lower()
                    if mime not in MIMES:
                        raise HTTPException(415, 'unsupported_audio_type')
                    audio = await upload.read(settings.max_audio_bytes + 1)
                    if len(audio) > settings.max_audio_bytes:
                        raise HTTPException(413, 'audio_too_large')
                    if not audio:
                        raise HTTPException(422, 'empty_audio')
            except (ValidationError, ValueError, UnicodeError):
                raise HTTPException(422, 'invalid_audio_metadata') from None
            except StarletteHTTPException as exc:
                # Multipart parser errors are reduced to fixed safe messages.
                if exc.status_code == 400:
                    raise HTTPException(400, 'invalid_multipart_body') from None
                raise
        else:
            raise HTTPException(415, 'use_json_or_multipart')

        actor=getattr(request.state,'actor',None)
        if actor is not None:
            if payload.site_id is None: raise HTTPException(422,'site_id_required')
            def check_scope():
                with Session(engine) as db: site_auth(db,actor,str(payload.site_id))
            await run_in_threadpool(check_scope)

        # Fail fast instead of an unbounded in-process queue; devices can retry 503.
        if slots.locked():
            raise HTTPException(503, 'briefing_capacity_reached', headers={'Retry-After':'5'})
        async with slots:
            try:
                async with asyncio.timeout(settings.briefing_timeout_seconds):
                    ai = request.app.state.provider
                    transcript = await ai.transcribe(audio, mime, payload.language) if audio is not None else redact(payload.text)
                    extracted = await ai.extract(transcript, payload.context)
                    calculations, warnings, probes = probe_site(extracted)
                    return BriefingResponse(site_id=payload.site_id, transcript=transcript,
                        extracted_data=extracted, calculations=calculations, warnings=warnings,
                        probes=probes, next_question_tamil=probes[0].question_tamil, provider=settings.ai_provider)
            except ProviderError as exc:
                raise HTTPException(exc.status, exc.code) from None
            except TimeoutError:
                raise HTTPException(504, 'briefing_timeout') from None

    # Register nested DTOs so manually declared JSON/multipart bodies resolve in OpenAPI.
    original_openapi = app.openapi
    def custom_openapi():
        schema = original_openapi()
        definitions = schema['paths']['/api/v1/ai/site-briefing']['post']['requestBody']['content']['application/json']['schema'].pop('$defs', {})
        schema.setdefault('components', {}).setdefault('schemas', {}).update(definitions)
        return schema
    app.openapi = custom_openapi
    return app
