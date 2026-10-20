import sqlite3
import unittest
from pathlib import Path

DDL = (Path(__file__).resolve().parents[1] / 'database/sqlite.sql').read_text()

class SchemaTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.addCleanup(self.db.close)
        self.db.executescript(DDL)
        for site in ('s1','s2'):
            self.insert('sites', id=site, name=site)
        self.insert('assets', id='nvr', site_id='s1', asset_type='NVR', channel_capacity=64)

    def insert(self, table, **values):
        values.update(created_at='2026-10-19T00:00:00Z', updated_at='2026-10-19T00:00:00Z')
        self.db.execute(f"INSERT INTO {table} ({','.join(values)}) VALUES ({','.join('?' for _ in values)})", list(values.values()))

    def test_cross_site_reference_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.insert('cameras', id='c', site_id='s2', nvr_id='nvr')

    def test_channel_reuse_only_after_tombstone(self):
        self.insert('cameras', id='c1', site_id='s1', nvr_id='nvr', channel_no=1)
        with self.assertRaises(sqlite3.IntegrityError):
            self.insert('cameras', id='c2', site_id='s1', nvr_id='nvr', channel_no=1)
        self.db.execute("UPDATE cameras SET deleted_at='2026-10-19T01:00:00Z' WHERE id='c1'")
        self.insert('cameras', id='c2', site_id='s1', nvr_id='nvr', channel_no=1)

    def test_interface_must_belong_to_connection_source(self):
        self.insert('assets', id='sw', site_id='s1', asset_type='Gigabit_Switch')
        self.insert('network_interfaces', id='nic', site_id='s1', asset_id='nvr', name='LAN2')
        with self.assertRaises(sqlite3.IntegrityError):
            self.insert('asset_connections', id='link', site_id='s1', from_asset_id='sw', to_asset_id='nvr', from_interface_id='nic', connection_type='ethernet')

    def test_invalid_coordinates_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.insert('sites', id='bad', name='Bad', gps_lat=91, gps_lng=80)

    def test_unknown_camera_details_allowed(self):
        self.insert('cameras', id='unknown', site_id='s1')
        self.assertEqual(self.db.execute("SELECT status FROM cameras WHERE id='unknown'").fetchone()[0], 'unknown')

    def test_invalid_poe_capacity_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.insert('assets', id='bad', site_id='s1', asset_type='PoE_Switch', port_capacity=8, poe_port_capacity=9)

if __name__ == '__main__':
    unittest.main()
