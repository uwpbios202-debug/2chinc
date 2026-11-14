-- Lease signing: tenants initial each initial line in the lease (the Parking Agreement's 22
-- sections) before they can sign. The lease-signing function checks every line was initialed,
-- stores the initials here, and prints them in the executed PDF where the blank lines were.
alter table lease_signing_signers add column if not exists initials text;
alter table lease_signing_signers add column if not exists initialed_sections jsonb;   -- the line ids initialed, e.g. ["1","2",…,"22"]
