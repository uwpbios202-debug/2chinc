-- Lease signing confirms the tenant with an EMAILED 6-digit code instead of a texted one (Stephen, 10/7/2026: no Twilio/SMS).
-- The code is sent only when the tenant taps "Email me a code", never on opening the page: email security scanners
-- open links, and an automatic send would email codes nobody asked for. Only a hash is stored; it expires in
-- 10 minutes and allows 5 tries. Sends are rate limited by the code_sent events in lease_signing_events.

alter table lease_signing_signers add column if not exists code_hash text;
alter table lease_signing_signers add column if not exists code_expires_at timestamptz;
alter table lease_signing_signers add column if not exists code_attempts int not null default 0;
