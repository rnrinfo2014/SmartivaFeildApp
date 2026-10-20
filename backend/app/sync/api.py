import hashlib
import json
import os
from pathlib import Path
import tempfile
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlalchemy.orm import Session

from .. import models as m
from .contracts import Mutation
from .service import (Actor, MODELS, append_change, authenticate, authorize, canonical,
                      lock_site, mutate, utc)

bearer=HTTPBearer(auto_error=False)

def session(request:Request):
    engine=request.app.state.db_engine
    if engine is None: raise HTTPException(503,'database_not_configured')
    with Session(engine) as db:
        yield db

def device(request:Request,credentials:HTTPAuthorizationCredentials | None=Depends(bearer)):
    if credentials is None: raise HTTPException(401,'device_token_required')
    engine=request.app.state.db_engine
    if engine is None: raise HTTPException(503,'database_not_configured')
    with Session(engine) as db: return authenticate(db,credentials.credentials)

router=APIRouter(prefix='/api/v1',tags=['sync'])

@router.get('/sync/me')
def me(actor:Actor=Depends(device)):
    return {'device_id':actor.device_id,'technician_id':actor.technician_id,'can_create_sites':actor.can_create_sites}

@router.post('/sync/push')
def push(body:Mutation,actor:Actor=Depends(device),db:Session=Depends(session)):
    # Authentication SELECT has already opened a read transaction.
    try:
        status,response=mutate(db,actor,body)
        db.commit()
        return JSONResponse(status_code=status,content=response)
    except IntegrityError:
        db.rollback();raise HTTPException(409,'inventory_constraint_conflict') from None
    except OperationalError:
        db.rollback();raise HTTPException(503,'database_temporarily_unavailable') from None

@router.get('/sync/sites')
def sites(after:str='',limit:Annotated[int,Query(ge=1,le=100)]=100,actor:Actor=Depends(device),db:Session=Depends(session)):
    records=list(db.scalars(select(m.Site).join(m.SiteGrant,m.Site.id==m.SiteGrant.site_id)
        .where(m.SiteGrant.technician_id==actor.technician_id,m.Site.id>after).order_by(m.Site.id).limit(limit+1)))
    return {'sites':[{'id':r.id,'name':r.name,'deleted_at':r.deleted_at.isoformat() if r.deleted_at else None} for r in records[:limit]],
            'next':records[limit-1].id if len(records)>limit else None}

@router.get('/sites/{site_id}/changes')
def changes(site_id:UUID,after:Annotated[int,Query(ge=0)]=0,through:Annotated[int | None,Query(ge=0)]=None,
            limit:Annotated[int,Query(ge=1,le=100)]=100,actor:Actor=Depends(device),db:Session=Depends(session)):
    key=str(site_id);authorize(db,actor,key)
    head=db.get(m.SiteSyncHead,key)
    high=head.revision if head else 0
    watermark=high if through is None else through
    if watermark>high or after>watermark: raise HTTPException(409,'invalid_sync_cursor')
    records=db.scalars(select(m.SiteChange).where(m.SiteChange.site_id==key,m.SiteChange.revision>after,
        m.SiteChange.revision<=watermark).order_by(m.SiteChange.revision).limit(limit))
    rows=[];size=0;cursor=after
    for r in records:
        item={'revision':r.revision,'entity_type':r.entity_type,'record':r.payload}
        count=len(json.dumps(item).encode())
        if rows and size+count>512000: break
        rows.append(item);size+=count;cursor=r.revision
    return {'site_id':key,'changes':rows,'cursor':cursor,'through':watermark,'has_more':cursor<watermark}


def _archive(engine,root:Path,actor:Actor,site_id:str,voice_id:str,data:bytes,digest:str,mime:str,language:str):
    with Session(engine) as db,db.begin():
        lock_site(db,site_id);authorize(db,actor,site_id,True)
        site=db.get(m.Site,site_id)
        if not site or site.deleted_at: raise HTTPException(409,'site_deleted')
        record=db.get(m.VoiceNote,voice_id)
        if record and (record.site_id!=site_id or record.deleted_at or record.sha256!=digest):
            raise HTTPException(409,'voice_identity_conflict')
        key=f'{site_id}/{digest}.audio'
        destination=root/key
        destination.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        # Fsync then atomic rename; orphan objects after a DB failure are safe to
        # collect only when no voice row references them. No automatic deletion.
        if not destination.exists() or hashlib.sha256(destination.read_bytes()).hexdigest()!=digest:
            handle,path=tempfile.mkstemp(dir=destination.parent,prefix='.upload-')
            try:
                with os.fdopen(handle,'wb') as file:
                    file.write(data);file.flush();os.fsync(file.fileno())
                os.replace(path,destination)
                directory=os.open(destination.parent,os.O_RDONLY)
                try: os.fsync(directory)
                finally: os.close(directory)
            finally:
                if os.path.exists(path): os.unlink(path)
        if record is None:
            record=m.VoiceNote(id=voice_id,site_id=site_id,object_key=key,sha256=digest,language=language,
                processing_status='uploaded',source='manual',extra={'mime':mime},created_at=utc(),updated_at=utc(),version=1)
            db.add(record);db.flush();append_change(db,site_id,record)
        return {'entity_type':'voice_notes','record':canonical(record)}

@router.put('/sites/{site_id}/voice/{voice_id}')
async def upload_voice(site_id:UUID,voice_id:UUID,request:Request,
    sha:Annotated[str,Header(alias='X-Audio-SHA256',pattern=r'^[a-f0-9]{64}$')],
    language:Annotated[str,Header(alias='X-Audio-Language',pattern=r'^(auto|ta|en)$')]='auto',
    actor:Actor=Depends(device)):
    mime=request.headers.get('content-type','').split(';',1)[0]
    if mime not in ('audio/mp4','audio/wav','audio/mpeg','audio/webm','audio/ogg','audio/flac'): raise HTTPException(415,'unsupported_audio_type')
    data=await request.body()
    if not data or len(data)>request.app.state.settings.max_audio_bytes: raise HTTPException(413,'invalid_audio_size')
    if hashlib.sha256(data).hexdigest()!=sha: raise HTTPException(422,'audio_checksum_mismatch')
    return await run_in_threadpool(_archive,request.app.state.db_engine,Path(request.app.state.settings.audio_storage_path),
                                   actor,str(site_id),str(voice_id),data,sha,mime,language)

@router.get('/sites/{site_id}/voice/{voice_id}')
def download_voice(site_id:UUID,voice_id:UUID,request:Request,actor:Actor=Depends(device),db:Session=Depends(session)):
    authorize(db,actor,str(site_id))
    voice=db.get(m.VoiceNote,str(voice_id))
    if not voice or voice.site_id!=str(site_id) or voice.deleted_at or not voice.object_key: raise HTTPException(404,'voice_not_found')
    path=Path(request.app.state.settings.audio_storage_path)/voice.object_key
    if not path.is_file(): raise HTTPException(503,'voice_storage_unavailable')
    return FileResponse(path,media_type=voice.extra.get('mime','application/octet-stream'),filename=f'{voice_id}.audio',
                        headers={'X-Audio-SHA256':voice.sha256,'Cache-Control':'private, no-store'})
