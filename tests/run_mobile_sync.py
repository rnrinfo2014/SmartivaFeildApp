"""Launch a loopback API, provision disposable test identity, run real Flutter HTTP sync.
SMARTIVA_TEST_DATABASE_URL must point to a disposable PostgreSQL database.
No provider keys or production device tokens are used.
"""
import hashlib
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
from uuid import uuid4

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import uvicorn
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from app import models as m
from app.config import Settings
from app.main import create_app
from app.manage import SERVER_TABLES

def main():
    url=os.environ['SMARTIVA_TEST_DATABASE_URL']
    engine=create_engine(url)
    if engine.dialect.name!='postgresql':raise RuntimeError('PostgreSQL required')
    m.Base.metadata.create_all(engine,tables=SERVER_TABLES)
    token=secrets.token_urlsafe(32);user=str(uuid4())
    with Session(engine) as db,db.begin():
        db.add(m.Technician(id=user,name='mobile-integration-'+user,can_create_sites=True));db.flush()
        db.add(m.DeviceAccess(id=str(uuid4()),technician_id=user,label='disposable-test',token_hash=hashlib.sha256(token.encode()).hexdigest()))
    with tempfile.TemporaryDirectory() as archive,socket.socket() as sock:
        sock.bind(('127.0.0.1',0));sock.listen(128)
        app=create_app(Settings(api_token='internal-test-only-'+secrets.token_urlsafe(32),database_url=url,audio_storage_path=archive))
        server=uvicorn.Server(uvicorn.Config(app,log_level='critical',access_log=False))
        thread=threading.Thread(target=server.run,kwargs={'sockets':[sock]},daemon=True);thread.start()
        try:
            for _ in range(200):
                if server.started:break
                if not thread.is_alive():raise RuntimeError('Test API startup failed')
                time.sleep(.05)
            else:raise RuntimeError('Test API startup timed out')
            env={**os.environ,'SMARTIVA_LIVE_URL':f'http://127.0.0.1:{sock.getsockname()[1]}','SMARTIVA_LIVE_TOKEN':token}
            result=subprocess.run([os.getenv('FLUTTER_BIN','/workspace/flutter-sdk/bin/flutter'),'test','--no-pub','test/sync_live_test.dart'],cwd=Path(__file__).resolve().parents[1]/'mobile',env=env,timeout=240)
        finally:
            server.should_exit=True;thread.join(10);engine.dispose()
    return result.returncode

if __name__=='__main__':sys.exit(main())
