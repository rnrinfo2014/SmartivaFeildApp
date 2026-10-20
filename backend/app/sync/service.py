"""PostgreSQL transactions are serialized per site, including first creation."""
from dataclasses import dataclass
from datetime import date, datetime, timezone
import hashlib
import json
import math
from uuid import UUID

from fastapi import HTTPException
from pydantic import ValidationError
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from .. import models as m
from ..ai.contracts import (SiteDraft, ContactDraft, FloorDraft, ZoneDraft, AssetDraft,
                           InterfaceDraft, CameraDraft, ConnectionDraft)
from .contracts import Mutation

MODELS = {c.__tablename__: c for c in (m.Site,m.SiteContact,m.Floor,m.Zone,m.Asset,
          m.NetworkInterface,m.Camera,m.Connection,m.Observation,m.VoiceNote)}
DRAFTS = dict(zip(['sites','site_contacts','floors','floors_and_zones','assets',
                  'network_interfaces','cameras','asset_connections'],
                 [SiteDraft,ContactDraft,FloorDraft,ZoneDraft,AssetDraft,InterfaceDraft,CameraDraft,ConnectionDraft]))
REFS = {'floors_and_zones':{'floor_id':'floors'},'assets':{'zone_id':'floors_and_zones'},
        'network_interfaces':{'asset_id':'assets'},
        'cameras':{'nvr_id':'assets','switch_id':'assets','zone_id':'floors_and_zones'},
        'asset_connections':{'from_asset_id':'assets','to_asset_id':'assets','from_interface_id':'network_interfaces'},
        'observations':{'asset_id':'assets'}}
LOCAL = {'credential_ref','local_file_ref'}
META = {'id','site_id','version','created_at','updated_at','deleted_at','source','extra'}
SENSITIVE = {'password','passwd','username','token','api_key','credential_ref','local_file_ref'}

@dataclass(frozen=True)
class Actor:
    device_id: str
    technician_id: str
    can_create_sites: bool

def utc(): return datetime.now(timezone.utc)
def json_value(value):
    if isinstance(value,(datetime,date)): return value.isoformat()
    return value

def canonical(record):
    return {c.name: json_value(getattr(record,c.name)) for c in record.__table__.columns if c.name not in LOCAL}

def authenticate(db: Session, token: str) -> Actor:
    hashed=hashlib.sha256(token.encode()).hexdigest()
    device=db.scalar(select(m.DeviceAccess).where(m.DeviceAccess.token_hash==hashed,m.DeviceAccess.revoked.is_(False)))
    user=db.get(m.Technician,device.technician_id) if device else None
    if not device or not user or not user.active: raise HTTPException(401,'invalid_device_token')
    return Actor(device.id,user.id,user.can_create_sites)

def authorize(db:Session,actor:Actor,site_id:str,write=False):
    grant=db.get(m.SiteGrant,(site_id,actor.technician_id))
    if not grant or (write and not grant.can_write): raise HTTPException(403,'site_access_denied')

def lock_site(db:Session,site_id:str):
    # A transaction-scoped advisory lock also covers a site that does not exist yet.
    key=int.from_bytes(hashlib.sha256(site_id.encode()).digest()[:8],'big',signed=True)
    db.execute(text('SELECT pg_advisory_xact_lock(:key)'),{'key':key})

def append_change(db:Session,site_id:str,record):
    head=db.get(m.SiteSyncHead,site_id)
    if head is None:
        head=m.SiteSyncHead(site_id=site_id,revision=0);db.add(head);db.flush()
    head.revision+=1
    db.flush()
    db.add(m.SiteChange(site_id=site_id,revision=head.revision,entity_type=record.__tablename__,
        entity_id=record.id,entity_version=record.version,payload=canonical(record)))
    return head.revision

def _safe_json(value):
    if isinstance(value,dict):
        if any(str(k).lower() in SENSITIVE for k in value): raise HTTPException(422,'sensitive_fields_forbidden')
        for item in value.values(): _safe_json(item)
    elif isinstance(value,list):
        for item in value: _safe_json(item)
    elif isinstance(value,float) and not math.isfinite(value): raise HTTPException(422,'invalid_json_metadata')
    elif not isinstance(value,(str,int,float,bool,type(None))): raise HTTPException(422,'invalid_json_metadata')

def validate_payload(table,raw,existing,site_id,entity_id):
    if len(json.dumps(raw,allow_nan=False).encode())>200000: raise HTTPException(422,'entity_payload_too_large')
    _safe_json(raw)
    model=MODELS[table]
    allowed={c.name for c in model.__table__.columns}-LOCAL
    if set(raw)-allowed: raise HTTPException(422,'unknown_entity_fields')
    if raw.get('id',entity_id)!=entity_id or (table!='sites' and raw.get('site_id',site_id)!=site_id):
        raise HTTPException(422,'entity_scope_mismatch')
    data=canonical(existing) if existing else {}
    data.update(raw)
    attributes={k:v for k,v in data.items() if k not in META}
    if table in DRAFTS:
        try:
            draft=DRAFTS[table].model_validate(attributes if table=='sites' else {'ref':entity_id,**attributes})
        except ValidationError: raise HTTPException(422,'invalid_entity_data') from None
        attributes=draft.model_dump(exclude={'ref'})
        for key,value in attributes.items():
            if key.endswith('_id') and value is not None:
                try: attributes[key]=str(UUID(value))
                except ValueError: raise HTTPException(422,'invalid_reference_uuid') from None
            elif key=='ip_address' and value is not None: attributes[key]=str(value)
    elif table=='observations':
        if not isinstance(attributes.get('kind'),str) or not isinstance(attributes.get('payload'),dict):
            raise HTTPException(422,'invalid_observation')
        if attributes.get('asset_id') is not None:
            try: attributes['asset_id']=str(UUID(attributes['asset_id']))
            except (ValueError,TypeError): raise HTTPException(422,'invalid_reference_uuid') from None
        confirmed=attributes.get('confirmed',False)
        if confirmed not in (True,False,0,1): raise HTTPException(422,'invalid_observation')
        attributes['confirmed']=bool(confirmed)
        try: attributes['observed_at']=datetime.fromisoformat(attributes.get('observed_at',''))
        except (ValueError,TypeError): raise HTTPException(422,'invalid_observation_timestamp') from None
        if attributes['observed_at'].tzinfo is None: raise HTTPException(422,'timestamp_requires_timezone')
    else: # Voice binary identity is set only by the archival endpoint.
        if existing is None: raise HTTPException(422,'upload_voice_first')
        if any(attributes.get(k)!=getattr(existing,k) for k in ('object_key','sha256')):
            raise HTTPException(422,'immutable_voice_identity')
        if attributes.get('language') not in ('auto','ta','en'): raise HTTPException(422,'invalid_voice_language')
        if attributes.get('processing_status') not in ('uploaded','complete'): raise HTTPException(422,'invalid_voice_status')
        transcript=attributes.get('transcript')
        if transcript is not None and (not isinstance(transcript,str) or len(transcript)>30000): raise HTTPException(422,'invalid_transcript')
        if attributes.get('processing_status')=='complete' and not transcript: raise HTTPException(422,'transcript_required')
    # SQL VARCHAR bounds are stricter than some initial proposal DTOs.
    for key,value in attributes.items():
        column=model.__table__.columns[key]
        length=getattr(column.type,'length',None)
        if isinstance(value,str) and length and len(value)>length: raise HTTPException(422,'field_too_long')
    if table=='sites' and not attributes.get('name'): raise HTTPException(422,'site_name_required')
    source=data.get('source','manual')
    if source not in ('manual','ai','discovery'): raise HTTPException(422,'invalid_source')
    extra=data.get('extra',{})
    if table=='voice_notes' and existing and extra!=existing.extra: raise HTTPException(422,'immutable_voice_metadata')
    if not isinstance(extra,dict) or len(json.dumps(extra).encode())>65536: raise HTTPException(422,'invalid_metadata')
    return {**attributes,'source':source,'extra':extra}

def validate_links(db,table,values,site_id):
    for field,parent in REFS.get(table,{}).items():
        value=values.get(field)
        if value is None: continue
        record=db.get(MODELS[parent],value)
        if record is None or record.site_id!=site_id or record.deleted_at is not None:
            raise HTTPException(409,'invalid_or_deleted_parent')
    if table=='cameras':
        nvr=db.get(m.Asset,values['nvr_id']) if values.get('nvr_id') else None
        switch=db.get(m.Asset,values['switch_id']) if values.get('switch_id') else None
        if nvr and nvr.asset_type not in ('NVR','DVR'): raise HTTPException(422,'invalid_recorder_type')
        if switch and switch.asset_type not in ('PoE_Switch','Gigabit_Switch'): raise HTTPException(422,'invalid_switch_type')
        if nvr and nvr.channel_capacity is not None and values.get('channel_no',0) and values['channel_no']>nvr.channel_capacity:
            raise HTTPException(422,'camera_channel_exceeds_capacity')
    if table=='asset_connections' and values.get('from_interface_id'):
        if db.get(m.NetworkInterface,values['from_interface_id']).asset_id!=values['from_asset_id']:
            raise HTTPException(422,'interface_ownership_mismatch')
    if table=='assets' and values.get('_id'):
        role=values.get('asset_type')
        for field,allowed in ((m.Camera.nvr_id,('NVR','DVR')),(m.Camera.switch_id,('PoE_Switch','Gigabit_Switch'))):
            if role not in allowed and db.scalar(select(m.Camera.id).where(field==values['_id'],m.Camera.deleted_at.is_(None))):
                raise HTTPException(422,'asset_role_in_use')
    if table=='assets' and values.get('channel_capacity') is not None:
        bad=db.scalar(select(m.Camera.id).where(m.Camera.nvr_id==values.get('_id'),m.Camera.deleted_at.is_(None),m.Camera.channel_no>values['channel_capacity'])) if values.get('_id') else None
        if bad: raise HTTPException(422,'capacity_below_existing_channels')

def _cascade(db,site_id,table,record):
    all_rows={name:list(db.scalars(select(model).where(model.site_id==site_id,model.deleted_at.is_(None))))
              for name,model in MODELS.items() if name!='sites'}
    dead={name:set() for name in MODELS};dead[table].add(record.id)
    if table=='sites':
        for name,records in all_rows.items(): dead[name].update(r.id for r in records)
    changed=True
    while changed:
        changed=False
        for name,records in all_rows.items():
            for row in records:
                if row.id in dead[name]: continue
                if any(getattr(row,field) in dead[parent] for field,parent in REFS.get(name,{}).items()):
                    dead[name].add(row.id);changed=True
    now=utc()
    ordered=[record]+[row for name,records in all_rows.items() for row in records if row.id in dead[name] and row is not record]
    revision=0
    for row in ordered:
        row.deleted_at=now;row.updated_at=now;row.version+=1
        db.flush();revision=append_change(db,site_id,row)
    return revision

def mutate(db:Session,actor:Actor,request:Mutation):
    site_id,entity_id,op_id=map(str,(request.site_id,request.entity_id,request.operation_id))
    lock_site(db,site_id)
    site=db.get(m.Site,site_id)
    creating=request.entity_type=='sites' and request.operation=='create' and site is None
    if creating:
        if not actor.can_create_sites or entity_id!=site_id: raise HTTPException(403,'site_creation_denied')
    else: authorize(db,actor,site_id,True)
    _safe_json(request.payload)
    hashed=hashlib.sha256(json.dumps(request.model_dump(mode='json'),sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest()
    receipt=db.get(m.SyncReceipt,op_id)
    if receipt:
        if receipt.device_id!=actor.device_id or receipt.request_sha256!=hashed: raise HTTPException(409,'operation_id_reused')
        return receipt.response['status'],receipt.response['body']
    record=db.get(MODELS[request.entity_type],entity_id)
    if record and (record.id if request.entity_type=='sites' else record.site_id)!=site_id:
        raise HTTPException(409,'entity_id_unavailable')
    current_version=record.version if record else 0
    conflict=(request.base_version!=current_version or
              (request.operation=='create' and record is not None) or
              (request.operation!='create' and record is None))
    if conflict:
        status,body=409,{'code':'version_conflict','current':canonical(record) if record else None,'entity_type':request.entity_type}
    elif record and record.deleted_at is not None:
        status,body=409,{'code':'record_deleted','current':canonical(record),'entity_type':request.entity_type}
    else:
        if site and site.deleted_at is not None: raise HTTPException(409,'site_deleted')
        if request.operation=='delete': revision=_cascade(db,site_id,request.entity_type,record)
        else:
            if request.operation=='create' and request.base_version!=0: raise HTTPException(422,'create_requires_zero_version')
            values=validate_payload(request.entity_type,request.payload,record,site_id,entity_id)
            validate_links(db,request.entity_type,{**values,'_id':entity_id},site_id)
            if record is None:
                record=MODELS[request.entity_type](id=entity_id,**({} if request.entity_type=='sites' else {'site_id':site_id}),version=1,created_at=utc(),updated_at=utc(),**values)
                db.add(record);db.flush()
                if creating:
                    db.add(m.SiteGrant(site_id=site_id,technician_id=actor.technician_id,can_write=True));db.flush()
            else:
                for key,value in values.items(): setattr(record,key,value)
                record.version+=1;record.updated_at=utc();db.flush()
            revision=append_change(db,site_id,record)
        status,body=200,{'record':canonical(record),'entity_type':request.entity_type,'revision':revision}
    db.add(m.SyncReceipt(operation_id=op_id,device_id=actor.device_id,request_sha256=hashed,response={'status':status,'body':body}))
    db.flush()
    return status,body
