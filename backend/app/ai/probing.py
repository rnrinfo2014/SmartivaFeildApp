"""Deterministic arithmetic and prioritized Tamil/Tanglish engineering questions."""
from math import ceil
from .contracts import ExtractedData, Probe, RecorderCalculation


def probe_site(data: ExtractedData):
    calculations, warnings, probes = [], [], []
    reports = {r.nvr_id: r for r in data.inventory_reports}
    switch_reports = {r.switch_id: r for r in data.switch_reports}
    ups_reports = {r.ups_id: r for r in data.ups_reports}
    zones = {z.ref: z for z in data.zones}
    floors = {f.ref: f for f in data.floors}

    def add(code, target, question):
        probes.append(Probe(code=code, target_ref=target, question_tamil=question))

    if not data.site.name:
        add('site_name', None, 'Indha site-oda peyar enna?')

    for asset in data.assets:
        if asset.asset_type not in ('NVR', 'DVR'):
            continue
        report = reports.get(asset.ref)
        cameras = [c for c in data.cameras if c.nvr_id == asset.ref]
        total = report.reported_total if report else None
        if report and report.brand_breakdown_complete:
            brand_total = sum(report.brand_counts.values())
            if total is None:
                total = brand_total
            elif total != brand_total:
                warnings.append(f'{asset.ref}: reported total differs from complete brand breakdown.')
                add('count_conflict', asset.ref, 'Camera total-um brand-wise count-um match aagala. Correct total evlo?')
                total = None
        if report and total is not None and sum(report.brand_counts.values()) > total:
            warnings.append(f'{asset.ref}: brand counts exceed reported total.')
            add('count_conflict', asset.ref, 'Brand-wise count total-ai vida adhigama irukku. Counts verify pannalama?')
            total = None
        if total is not None and len(cameras) > total:
            warnings.append(f'{asset.ref}: individual camera records exceed reported total.')
            add('count_conflict', asset.ref, 'Document panna cameras reported total-ai vida adhigam. Correct count evlo?')
            total = None
        active = report.reported_active if report else None
        if active is not None and total is not None and active > total:
            warnings.append(f'{asset.ref}: active count exceeds total.')
            add('active_conflict', asset.ref, 'Active camera count total-ai vida adhigam. Online count verify pannunga.')
            active = None
        free = asset.channel_capacity - total if asset.channel_capacity is not None and total is not None else None
        if free is not None and free < 0:
            warnings.append(f'{asset.ref}: reported cameras exceed channel capacity.')
            add('capacity_exceeded', asset.ref, 'Camera count NVR capacity-ai vida adhigam. Vera recorder irukka, illa count correct pannanuma?')
            free = None
        if asset.channel_capacity is not None and any(c.channel_no and c.channel_no > asset.channel_capacity for c in cameras):
            warnings.append(f'{asset.ref}: a camera channel exceeds recorder capacity.')
            add('channel_exceeded', asset.ref, 'Oru camera channel NVR capacity-ku veliya irukku. Channel number correct-aa?')
        poe_count = report.poe_camera_count if report else None
        if poe_count is not None and total is not None and poe_count > total:
            warnings.append(f'{asset.ref}: PoE camera count exceeds total.')
            add('poe_count_conflict', asset.ref, 'PoE camera count total-ai vida adhigam. PoE count evlo?')
            poe_count = None
        estimates = {str(ports): ceil(poe_count / ports) for ports in (8, 16, 24)} if poe_count is not None else {}
        calculations.append(RecorderCalculation(nvr_id=asset.ref, capacity=asset.channel_capacity,
            reported_total=total, reported_active=active, individually_documented=len(cameras),
            free_channels=free, poe_minimum_switches=estimates))
        if asset.channel_capacity is None:
            add('recorder_capacity', asset.ref, 'Indha NVR/DVR ethana channels support pannum?')
        if total is None:
            add('camera_total', asset.ref, 'Indha recorder-la motham ethana cameras configure pannirukkinga?')
        elif active is None:
            add('active_cameras', asset.ref, f'{total} cameras mention pannirukkinga. Ippo ethana online-la irukku?')
        if asset.asset_type == 'NVR' and poe_count is None:
            add('poe_count', asset.ref, 'Indha cameras-la ethana PoE power use pannudhu? Separate power / Wi-Fi cameras irukka?')
        links = [l for l in data.connectivity if asset.ref in (l.from_asset_id, l.to_asset_id) and l.connection_type in ('ethernet','fiber')]
        if asset.asset_type == 'NVR' and not links:
            add('recorder_network', asset.ref, 'NVR endha switch-ku connect aagudhu? Internet LAN-um camera LAN-um separate ports-aa?')

    switches = [a for a in data.assets if a.asset_type in ('PoE_Switch','Gigabit_Switch')]
    if any(a.asset_type == 'NVR' for a in data.assets) and not switches:
        add('switch_inventory', None, 'Floor-wise ethana PoE / network switches irukku? Ovvoru switch-oda port count enna?')
    for switch in switches:
        zone = zones.get(switch.zone_id)
        floor = floors.get(zone.floor_id) if zone else None
        location = f'{floor.name} / {zone.zone_name}' if floor and zone else switch.ref
        if not zone:
            add('switch_location', switch.ref, 'Indha switch endha floor, endha room / steps pakkam irukku?')
        if switch.port_capacity is None:
            add('switch_ports', switch.ref, f'{location} switch-la total ethana ports irukku?')
        attached = [c for c in data.cameras if c.switch_id == switch.ref]
        if not attached:
            add('switch_camera_mapping', switch.ref, f'{location} switch-ku endha cameras connect aagudhu? Camera locations / channels sollunga.')
        if switch.port_capacity is not None and len(attached) > switch.port_capacity:
            warnings.append(f'{switch.ref}: documented cameras exceed switch port capacity.')
        report = switch_reports.get(switch.ref)
        if not report or any(v is None for v in (report.used_ports, report.free_ports, report.faulty_ports, report.uplink_port)):
            add('port_status', switch.ref, f'{location} switch-la used, free, faulty ports ethana? Uplink endha port-la irukku?')
        if report and switch.port_capacity is not None:
            counts = (report.used_ports, report.free_ports, report.faulty_ports)
            if all(v is not None for v in counts) and sum(counts) != switch.port_capacity:
                warnings.append(f'{switch.ref}: mutually exclusive used/free/faulty counts do not match port capacity.')
                add('port_count_conflict', switch.ref, 'Used, free, faulty port counts total capacity-oda match aagala. Counts verify pannunga.')
        if switch.asset_type == 'PoE_Switch' and switch.poe_port_capacity is None:
            add('poe_capacity', switch.ref, f'{location} switch-la ethana PoE ports? PoE watt budget theriyuma?')

    for asset in data.assets:
        if asset.asset_type not in ('NVR','DVR','PoE_Switch','Gigabit_Switch'):
            continue
        backups = [l for l in data.connectivity if l.connection_type == 'power' and asset.ref in (l.from_asset_id,l.to_asset_id)
                   and any(a.asset_type == 'UPS' and a.ref in (l.from_asset_id,l.to_asset_id) for a in data.assets)]
        if not backups:
            add('ups_mapping', asset.ref, 'Indha device-ku UPS backup irukka? Endha UPS, endha floor, evlo neram backup kidaikkum?')
    for ups in (a for a in data.assets if a.asset_type == 'UPS'):
        report = ups_reports.get(ups.ref)
        if not report or report.tested_backup_minutes is None or (report.capacity_va is None and report.capacity_watts is None) or report.battery_install_year is None:
            add('ups_runtime', ups.ref, 'UPS capacity VA/W evlo? Connected load-la test panna backup minutes, battery age enna?')
    if not data.floors:
        add('floor_inventory', None, 'Site-la ethana floors? Basement / ground / first floor-wise sollunga.')
    if not data.contacts:
        add('site_contact', None, 'Site incharge peyar, role, contact number enna?')
    if not probes:
        add('review', None, 'Site details review pannunga. Missing device, floor illa connection irundha sollunga.')
    # Stable, unique prompts; client shows the first, retaining the rest as a checklist.
    probes = list({(p.code, p.target_ref): p for p in probes}.values())
    return calculations, warnings, probes
