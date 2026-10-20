"""Trusted operator CLI. No public account provisioning endpoint."""
import argparse
import hashlib
import json
import secrets
from uuid import uuid4

from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session
from .config import Settings
from . import models as m
from .sync.service import MODELS, append_change, lock_site

SERVER_TABLES=[t for name,t in m.Base.metadata.tables.items() if name not in {'sync_outbox','sync_cursors'}]

def main():
    parser=argparse.ArgumentParser()
    sub=parser.add_subparsers(dest='command',required=True)
    sub.add_parser('init-db')
    issue=sub.add_parser('issue-device');issue.add_argument('--technician',required=True);issue.add_argument('--label',required=True)
    grant=sub.add_parser('grant');grant.add_argument('--technician',required=True);grant.add_argument('--site-id',required=True);grant.add_argument('--read-only',action='store_true')
    revoke=sub.add_parser('revoke-device');revoke.add_argument('--device-id',required=True)
    args=parser.parse_args();config=Settings()
    if not config.database_url: parser.error('SMARTIVA_DATABASE_URL is required')
    engine=create_engine(config.database_url.get_secret_value(),pool_pre_ping=True)
    if engine.dialect.name!='postgresql': parser.error('Sync requires PostgreSQL')
    if args.command=='init-db':
        m.Base.metadata.create_all(engine,tables=SERVER_TABLES)
        with Session(engine) as db,db.begin():
            for site in db.scalars(select(m.Site)):
                lock_site(db,site.id)
                if db.get(m.SiteSyncHead,site.id): continue
                append_change(db,site.id,site)
                # Dependency order mirrors initial schema and pull requirements.
                for name in ('site_contacts','floors','floors_and_zones','assets','network_interfaces','cameras','asset_connections','observations','voice_notes'):
                    for record in db.scalars(select(MODELS[name]).where(MODELS[name].site_id==site.id)):
                        append_change(db,site.id,record)
        print('Server schema initialized; existing site histories backfilled.')
        return
    with Session(engine) as db,db.begin():
        if args.command=='revoke-device':
            device=db.get(m.DeviceAccess,args.device_id)
            if not device: parser.error('Device not found')
            device.revoked=True;return
        user=db.scalar(select(m.Technician).where(m.Technician.name==args.technician))
        if args.command=='issue-device':
            if not user:
                user=m.Technician(id=str(uuid4()),name=args.technician,active=True,can_create_sites=True);db.add(user);db.flush()
            token=secrets.token_urlsafe(32)
            device=m.DeviceAccess(id=str(uuid4()),technician_id=user.id,label=args.label,
                                  token_hash=hashlib.sha256(token.encode()).hexdigest(),revoked=False)
            db.add(device);db.flush()
            output={'device_id':device.id,'technician_id':user.id,'token':token}
        else:
            if not user or not db.get(m.Site,args.site_id): parser.error('Technician or site not found')
            grant=db.get(m.SiteGrant,(args.site_id,user.id))
            if grant: grant.can_write=not args.read_only
            else: db.add(m.SiteGrant(site_id=args.site_id,technician_id=user.id,can_write=not args.read_only))
            output={'granted':True}
    print(json.dumps(output)) # Newly generated token shown once, never logged by API.

if __name__=='__main__': main()
