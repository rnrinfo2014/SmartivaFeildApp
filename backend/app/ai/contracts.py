"""Validated proposal DTOs; reviewed proposals are mapped to ORM records later."""
from datetime import date
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, IPvAnyAddress, model_validator

Name = Annotated[str, Field(min_length=1, max_length=160)]
Count = Annotated[int, Field(strict=True, ge=0, le=100000)]
Key = Annotated[str, Field(pattern=r'^[a-zA-Z0-9_-]{1,64}$')]

class StrictModel(BaseModel):
    model_config = ConfigDict(extra='forbid', str_strip_whitespace=True)

class Entity(StrictModel):
    # Stable proposal-local refs; existing IDs can be reused as keys in context.
    ref: Key

class SiteDraft(StrictModel):
    name: Name | None = None
    gps_lat: Annotated[float, Field(ge=-90, le=90)] | None = None
    gps_lng: Annotated[float, Field(ge=-180, le=180)] | None = None
    address: Annotated[str, Field(max_length=2000)] | None = None
    landmarks: Annotated[str, Field(max_length=1000)] | None = None

    @model_validator(mode='after')
    def coordinates(self):
        if (self.gps_lat is None) != (self.gps_lng is None):
            raise ValueError('Both GPS coordinates are required together')
        return self

class ContactDraft(Entity):
    name: Name
    role: Name | None = None
    phone: Annotated[str, Field(max_length=40)] | None = None

class FloorDraft(Entity):
    name: Name
    level: int | None = None

class ZoneDraft(Entity):
    floor_id: Key
    zone_name: Name

AssetType = Literal['NVR','DVR','PoE_Switch','Gigabit_Switch','UPS','EPABX','Router','ISP']

class AssetDraft(Entity):
    zone_id: Key | None = None
    asset_type: AssetType
    brand: Name | None = None
    model: Name | None = None
    channel_capacity: Count | None = None
    port_capacity: Count | None = None
    poe_port_capacity: Count | None = None
    serial_number: Name | None = None
    installed_date: date | None = None
    notes: Annotated[str, Field(max_length=2000)] | None = None

    @model_validator(mode='after')
    def capacities(self):
        if self.poe_port_capacity is not None and self.port_capacity is not None and self.poe_port_capacity > self.port_capacity:
            raise ValueError('PoE ports exceed total ports')
        return self

class InterfaceDraft(Entity):
    asset_id: Key
    name: Name
    purpose: Name | None = None
    ip_address: IPvAnyAddress | None = None
    prefix_length: Annotated[int, Field(ge=0, le=128)] | None = None
    mac_address: Annotated[str, Field(pattern=r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$')] | None = None

    @model_validator(mode='after')
    def prefix(self):
        if self.ip_address and self.ip_address.version == 4 and self.prefix_length is not None and self.prefix_length > 32:
            raise ValueError('Invalid IPv4 prefix')
        return self

class CameraDraft(Entity):
    nvr_id: Key | None = None
    switch_id: Key | None = None
    zone_id: Key | None = None
    brand: Name | None = None
    megapixel: Annotated[float, Field(gt=0, le=1000)] | None = None
    camera_type: Literal['IP','Analog','Wi-Fi'] | None = None
    ip_address: IPvAnyAddress | None = None
    mac_address: Annotated[str, Field(pattern=r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$')] | None = None
    serial_number: Name | None = None
    channel_no: Annotated[int, Field(strict=True, gt=0, le=100000)] | None = None
    install_year: Annotated[int, Field(ge=1900, le=2200)] | None = None
    status: Literal['online','offline','faulty','unknown'] = 'unknown'

class ConnectionDraft(Entity):
    from_asset_id: Key
    to_asset_id: Key
    from_interface_id: Key | None = None
    from_port: Name | None = None
    to_port: Name | None = None
    connection_type: Literal['ethernet','fiber','power','wireless','telephone']
    notes: Annotated[str, Field(max_length=2000)] | None = None

class InventoryReport(StrictModel):
    """One recorder's reported counts; null total means coverage is unknown."""
    nvr_id: Key
    reported_total: Count | None = None
    brand_counts: dict[Name, Count] = Field(default_factory=dict, max_length=100)
    brand_breakdown_complete: bool = False
    reported_active: Count | None = None
    poe_camera_count: Count | None = None

class SwitchReport(StrictModel):
    switch_id: Key
    used_ports: Count | None = None
    free_ports: Count | None = None
    faulty_ports: Count | None = None
    uplink_port: Name | None = None
    poe_budget_watts: Annotated[float, Field(ge=0)] | None = None

class UPSReport(StrictModel):
    ups_id: Key
    capacity_va: Annotated[float, Field(gt=0)] | None = None
    capacity_watts: Annotated[float, Field(gt=0)] | None = None
    tested_backup_minutes: Annotated[float, Field(ge=0)] | None = None
    battery_install_year: Annotated[int, Field(ge=1900, le=2200)] | None = None

class ExtractedData(StrictModel):
    site: SiteDraft = Field(default_factory=SiteDraft)
    contacts: list[ContactDraft] = Field(default_factory=list, max_length=100)
    floors: list[FloorDraft] = Field(default_factory=list, max_length=100)
    zones: list[ZoneDraft] = Field(default_factory=list, max_length=500)
    assets: list[AssetDraft] = Field(default_factory=list, max_length=1000)
    network_interfaces: list[InterfaceDraft] = Field(default_factory=list, max_length=2000)
    cameras: list[CameraDraft] = Field(default_factory=list, max_length=4000)
    connectivity: list[ConnectionDraft] = Field(default_factory=list, max_length=2000)
    inventory_reports: list[InventoryReport] = Field(default_factory=list, max_length=100)

    switch_reports: list[SwitchReport] = Field(default_factory=list, max_length=1000)
    ups_reports: list[UPSReport] = Field(default_factory=list, max_length=1000)

    @model_validator(mode='after')
    def references(self):
        collections = [self.contacts, self.floors, self.zones, self.assets, self.network_interfaces, self.cameras, self.connectivity]
        refs = [e.ref for group in collections for e in group]
        if len(refs) != len(set(refs)):
            raise ValueError('Proposal refs must be globally unique')
        floors = {e.ref for e in self.floors}
        zones = {e.ref for e in self.zones}
        assets = {e.ref: e for e in self.assets}
        interfaces = {e.ref: e for e in self.network_interfaces}
        def exists(value, items):
            if value is not None and value not in items:
                raise ValueError('Unresolved proposal reference')
        for z in self.zones:
            exists(z.floor_id, floors)
        for a in self.assets:
            exists(a.zone_id, zones)
        for nic in self.network_interfaces:
            exists(nic.asset_id, assets)
        channels = set()
        for c in self.cameras:
            exists(c.zone_id, zones)
            exists(c.nvr_id, assets)
            exists(c.switch_id, assets)
            if c.nvr_id and assets[c.nvr_id].asset_type not in ('NVR','DVR'):
                raise ValueError('Recorder reference has wrong asset type')
            if c.switch_id and assets[c.switch_id].asset_type not in ('PoE_Switch','Gigabit_Switch'):
                raise ValueError('Switch reference has wrong asset type')
            if c.nvr_id and c.channel_no is not None:
                key = (c.nvr_id, c.channel_no)
                if key in channels:
                    raise ValueError('Duplicate recorder channel')
                channels.add(key)
        for link in self.connectivity:
            exists(link.from_asset_id, assets)
            exists(link.to_asset_id, assets)
            exists(link.from_interface_id, interfaces)
            if link.from_asset_id == link.to_asset_id:
                raise ValueError('Self connection')
            if link.from_interface_id and interfaces[link.from_interface_id].asset_id != link.from_asset_id:
                raise ValueError('Interface does not belong to source asset')
        reported = set()
        for report in self.inventory_reports:
            exists(report.nvr_id, assets)
            if assets[report.nvr_id].asset_type not in ('NVR','DVR') or report.nvr_id in reported:
                raise ValueError('Invalid or duplicate recorder report')
            reported.add(report.nvr_id)
        for reports, field, types in ((self.switch_reports, 'switch_id', ('PoE_Switch','Gigabit_Switch')), (self.ups_reports, 'ups_id', ('UPS',))):
            seen = set()
            for report in reports:
                key = getattr(report, field)
                exists(key, assets)
                if assets[key].asset_type not in types or key in seen:
                    raise ValueError('Invalid or duplicate operational report')
                seen.add(key)
        return self

class BriefingRequest(StrictModel):
    text: Annotated[str, Field(min_length=1, max_length=30000)]
    site_id: UUID | None = None
    language: Literal['auto','ta','en'] = 'auto'
    context: ExtractedData | None = None

class RecorderCalculation(StrictModel):
    nvr_id: str
    capacity: int | None
    reported_total: int | None
    reported_active: int | None
    individually_documented: int
    free_channels: int | None
    poe_minimum_switches: dict[str, int]
    # Conditional lower bounds only: no uplink reservation or power budget implied.

class Probe(StrictModel):
    code: str
    target_ref: str | None = None
    question_tamil: str

class BriefingResponse(StrictModel):
    site_id: UUID | None
    transcript: str
    extracted_data: ExtractedData
    calculations: list[RecorderCalculation]
    warnings: list[str]
    probes: list[Probe]
    next_question_tamil: str
    requires_confirmation: Literal[True] = True
    provider: Literal['gemini','groq']
