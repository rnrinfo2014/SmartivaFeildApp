-- Step 5 additive PostgreSQL migration. Apply once inside a transaction.

BEGIN;

CREATE TABLE technicians (
	id VARCHAR(36) NOT NULL, 
	name VARCHAR(160) NOT NULL, 
	active BOOLEAN NOT NULL, 
	can_create_sites BOOLEAN NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (name)
);

CREATE TABLE device_access (
	id VARCHAR(36) NOT NULL, 
	technician_id VARCHAR(36) NOT NULL, 
	label VARCHAR(160) NOT NULL, 
	token_hash VARCHAR(64) NOT NULL, 
	revoked BOOLEAN NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(technician_id) REFERENCES technicians (id), 
	UNIQUE (token_hash)
);

CREATE TABLE site_grants (
	site_id VARCHAR(36) NOT NULL, 
	technician_id VARCHAR(36) NOT NULL, 
	can_write BOOLEAN NOT NULL, 
	PRIMARY KEY (site_id, technician_id), 
	FOREIGN KEY(site_id) REFERENCES sites (id), 
	FOREIGN KEY(technician_id) REFERENCES technicians (id)
);

COMMIT;
