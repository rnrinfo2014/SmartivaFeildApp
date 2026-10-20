"""Portable SQLAlchemy 2 models. UUIDs and UTC timestamps are supplied by clients.

Server writes must use optimistic version checks; see database/README.md.
"""
from datetime import date, datetime, timezone
from uuid import uuid4

from sqlalchemy import (
    Boolean, CheckConstraint, Date, DateTime, Float, ForeignKeyConstraint,
    Index, Integer, JSON, String, Text, UniqueConstraint, text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

Json = JSON().with_variant(JSONB(), 'postgresql')

def utcnow():
    return datetime.now(timezone.utc)

class Base(DeclarativeBase):
    pass

class Record:
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    version: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text('1'))
    source: Mapped[str] = mapped_column(String(24), nullable=False, server_default=text("'manual'"))
    extra: Mapped[dict] = mapped_column(Json, nullable=False, default=dict, server_default=text("'{}'"))

class Site(Record, Base):
    __tablename__ = 'sites'
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    gps_lat: Mapped[float | None] = mapped_column(Float)
    gps_lng: Mapped[float | None] = mapped_column(Float)
    address: Mapped[str | None] = mapped_column(Text)
    landmarks: Mapped[str | None] = mapped_column(Text)
    __table_args__ = (
        CheckConstraint('gps_lat BETWEEN -90 AND 90'),
        CheckConstraint('gps_lng BETWEEN -180 AND 180'),
        CheckConstraint('(gps_lat IS NULL) = (gps_lng IS NULL)'),
    )

class SiteRecord(Record):
    site_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)

# Composite foreign keys enforce that all referenced records belong to one site.
def scope(*constraints):
    return (ForeignKeyConstraint(['site_id'], ['sites.id']),
            UniqueConstraint('site_id', 'id'), *constraints)

def ref(column, table):
    return ForeignKeyConstraint(['site_id', column], [f'{table}.site_id', f'{table}.id'])

class SiteContact(SiteRecord, Base):
    __tablename__ = 'site_contacts'
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    role: Mapped[str | None] = mapped_column(String(80))
    phone: Mapped[str | None] = mapped_column(String(40))
    __table_args__ = scope()

class Floor(SiteRecord, Base):
    __tablename__ = 'floors'
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    level: Mapped[int | None] = mapped_column(Integer)
    __table_args__ = scope(UniqueConstraint('site_id', 'name'))

class Zone(SiteRecord, Base):
    __tablename__ = 'floors_and_zones'
    floor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    zone_name: Mapped[str] = mapped_column(String(160), nullable=False)
    __table_args__ = scope(ref('floor_id', 'floors'), UniqueConstraint('site_id', 'floor_id', 'zone_name'))

class Asset(SiteRecord, Base):
    __tablename__ = 'assets'
    zone_id: Mapped[str | None] = mapped_column(String(36))
    asset_type: Mapped[str] = mapped_column(String(32), nullable=False)
    brand: Mapped[str | None] = mapped_column(String(80))
    model: Mapped[str | None] = mapped_column(String(160))
    channel_capacity: Mapped[int | None] = mapped_column(Integer)
    port_capacity: Mapped[int | None] = mapped_column(Integer)
    poe_port_capacity: Mapped[int | None] = mapped_column(Integer)
    serial_number: Mapped[str | None] = mapped_column(String(160))
    credential_ref: Mapped[str | None] = mapped_column(String(240))
    installed_date: Mapped[date | None] = mapped_column(Date)
    notes: Mapped[str | None] = mapped_column(Text)
    __table_args__ = scope(ref('zone_id', 'floors_and_zones'),
        CheckConstraint("asset_type IN ('NVR','DVR','PoE_Switch','Gigabit_Switch','UPS','EPABX','Router','ISP')"),
        CheckConstraint('channel_capacity >= 0'), CheckConstraint('port_capacity >= 0'),
        CheckConstraint('poe_port_capacity >= 0 AND poe_port_capacity <= port_capacity'))

class NetworkInterface(SiteRecord, Base):
    __tablename__ = 'network_interfaces'
    asset_id: Mapped[str] = mapped_column(String(36), nullable=False)
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    purpose: Mapped[str | None] = mapped_column(String(80))
    ip_address: Mapped[str | None] = mapped_column(String(45))
    prefix_length: Mapped[int | None] = mapped_column(Integer)
    mac_address: Mapped[str | None] = mapped_column(String(17))
    __table_args__ = scope(ref('asset_id', 'assets'), UniqueConstraint('site_id','asset_id','name'),
                          CheckConstraint('prefix_length BETWEEN 0 AND 128'))

class Camera(SiteRecord, Base):
    __tablename__ = 'cameras'
    nvr_id: Mapped[str | None] = mapped_column(String(36))
    switch_id: Mapped[str | None] = mapped_column(String(36))
    zone_id: Mapped[str | None] = mapped_column(String(36))
    brand: Mapped[str | None] = mapped_column(String(80))
    megapixel: Mapped[float | None] = mapped_column(Float)
    camera_type: Mapped[str | None] = mapped_column(String(16))
    ip_address: Mapped[str | None] = mapped_column(String(45))
    mac_address: Mapped[str | None] = mapped_column(String(17))
    serial_number: Mapped[str | None] = mapped_column(String(160))
    channel_no: Mapped[int | None] = mapped_column(Integer)
    install_year: Mapped[int | None] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(24), nullable=False, server_default=text("'unknown'"))
    __table_args__ = scope(ref('nvr_id','assets'), ref('switch_id','assets'), ref('zone_id','floors_and_zones'),
        CheckConstraint("camera_type IN ('IP','Analog','Wi-Fi')"),
        CheckConstraint("status IN ('online','offline','faulty','unknown')"),
        CheckConstraint('channel_no > 0'), CheckConstraint('megapixel > 0'),
        CheckConstraint('install_year BETWEEN 1900 AND 2200'))

Index('uq_live_camera_channel', Camera.site_id, Camera.nvr_id, Camera.channel_no,
      unique=True, sqlite_where=Camera.deleted_at.is_(None), postgresql_where=Camera.deleted_at.is_(None))

class Connection(SiteRecord, Base):
    __tablename__ = 'asset_connections'
    from_asset_id: Mapped[str] = mapped_column(String(36), nullable=False)
    to_asset_id: Mapped[str] = mapped_column(String(36), nullable=False)
    from_interface_id: Mapped[str | None] = mapped_column(String(36))
    from_port: Mapped[str | None] = mapped_column(String(40))
    to_port: Mapped[str | None] = mapped_column(String(40))
    connection_type: Mapped[str] = mapped_column(String(24), nullable=False)
    notes: Mapped[str | None] = mapped_column(Text)
    __table_args__ = scope(ref('from_asset_id','assets'), ref('to_asset_id','assets'),
        ForeignKeyConstraint(['site_id','from_asset_id','from_interface_id'],
            ['network_interfaces.site_id','network_interfaces.asset_id','network_interfaces.id']),
        CheckConstraint('from_asset_id <> to_asset_id'),
        CheckConstraint("connection_type IN ('ethernet','fiber','power','wireless','telephone')"))

# Required as the target of the connection interface ownership FK.
NetworkInterface.__table__.append_constraint(UniqueConstraint('site_id','asset_id','id'))

class Observation(SiteRecord, Base):
    """Reported aggregate counts and discovery/AI evidence; never synthetic cameras."""
    __tablename__ = 'observations'
    asset_id: Mapped[str | None] = mapped_column(String(36))
    kind: Mapped[str] = mapped_column(String(40), nullable=False)
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utcnow)
    payload: Mapped[dict] = mapped_column(Json, nullable=False)
    confirmed: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default=text('false'))
    __table_args__ = scope(ref('asset_id','assets'))

class VoiceNote(SiteRecord, Base):
    __tablename__ = 'voice_notes'
    local_file_ref: Mapped[str | None] = mapped_column(Text)
    object_key: Mapped[str | None] = mapped_column(Text)
    sha256: Mapped[str | None] = mapped_column(String(64))
    language: Mapped[str] = mapped_column(String(20), nullable=False, server_default=text("'auto'"))
    transcript: Mapped[str | None] = mapped_column(Text)
    processing_status: Mapped[str] = mapped_column(String(24), nullable=False, server_default=text("'pending'"))
    __table_args__ = scope(CheckConstraint("processing_status IN ('pending','uploaded','processing','complete','failed')"))

# Device-local tables: excluded from PostgreSQL DDL by the generator.
class SyncOutbox(Base):
    __tablename__ = 'sync_outbox'
    operation_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    site_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    entity_type: Mapped[str] = mapped_column(String(60), nullable=False)
    entity_id: Mapped[str] = mapped_column(String(36), nullable=False)
    operation: Mapped[str] = mapped_column(String(12), nullable=False)
    base_version: Mapped[int] = mapped_column(Integer, nullable=False)
    payload: Mapped[dict] = mapped_column(Json, nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False, server_default=text("'pending'"))
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text('0'))
    next_attempt_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    lease_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utcnow)
    __table_args__ = (CheckConstraint("operation IN ('create','update','delete','upload')"),
        CheckConstraint("status IN ('pending','inflight','conflict','failed')"),
        CheckConstraint('base_version >= 0 AND attempts >= 0'),
        Index('ix_outbox_ready','status','next_attempt_at'))

class SyncCursor(Base):
    __tablename__ = 'sync_cursors'
    site_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    server_cursor: Mapped[str | None] = mapped_column(Text)
    last_synced_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

# Server-local durable idempotency receipts. Response stored atomically with mutation.
class SyncReceipt(Base):
    __tablename__ = 'sync_receipts'
    operation_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    device_id: Mapped[str] = mapped_column(String(36), nullable=False)
    request_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    response: Mapped[dict] = mapped_column(Json, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utcnow)

class SiteSyncHead(Base):
    __tablename__ = 'site_sync_heads'
    site_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    revision: Mapped[int] = mapped_column(Integer, nullable=False, server_default=text('0'))
    __table_args__ = (ForeignKeyConstraint(['site_id'], ['sites.id']), CheckConstraint('revision >= 0'))

class SiteChange(Base):
    __tablename__ = 'site_changes'
    site_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    revision: Mapped[int] = mapped_column(Integer, primary_key=True)
    entity_type: Mapped[str] = mapped_column(String(60), nullable=False)
    entity_id: Mapped[str] = mapped_column(String(36), nullable=False)
    entity_version: Mapped[int] = mapped_column(Integer, nullable=False)
    payload: Mapped[dict] = mapped_column(Json, nullable=False)
    __table_args__ = (ForeignKeyConstraint(['site_id'], ['sites.id']), CheckConstraint('revision > 0'))

for table in Base.metadata.tables.values():
    if 'version' in table.c:
        table.append_constraint(CheckConstraint('version >= 1', name=f'ck_{table.name}_version'))

class Technician(Base):
    __tablename__ = 'technicians'
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    name: Mapped[str] = mapped_column(String(160), nullable=False, unique=True)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    can_create_sites: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

class DeviceAccess(Base):
    __tablename__ = 'device_access'
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    technician_id: Mapped[str] = mapped_column(String(36), nullable=False)
    label: Mapped[str] = mapped_column(String(160), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    revoked: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    __table_args__ = (ForeignKeyConstraint(['technician_id'], ['technicians.id']),)

class SiteGrant(Base):
    __tablename__ = 'site_grants'
    site_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    technician_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    can_write: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    __table_args__ = (ForeignKeyConstraint(['site_id'], ['sites.id']),
                      ForeignKeyConstraint(['technician_id'], ['technicians.id']))
