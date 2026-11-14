-- Gap #6 (docs/leasing-gap-analysis.md): staff can void a lease sent for signature and re-send a tenant's signing link
-- (the lease-signing function's "void" and "resend" actions). The staff list now carries each signer's id (for re-send),
-- the void reason, and leaves voided leases at the bottom.

create or replace function lease_signing_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'unit_label', d.unit_label, 'title', d.title, 'status', d.status, 'created_at', d.created_at,
      'created_by', d.created_by, 'executed_at', d.executed_at, 'executed_pdf_path', d.executed_pdf_path,
      'application_id', d.application_id, 'agent_name', a.name, 'agent_signed_at', d.agent_signed_at, 'void_reason', d.void_reason,
      'signers', (select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'email', s.email, 'sent_at', s.sent_at, 'viewed_at', s.viewed_at,
                   'verified_at', s.verified_at, 'signed_at', s.signed_at) order by s.position) from lease_signing_signers s where s.doc_id = d.id))
      order by d.status = 'void', d.created_at desc) from lease_signing_docs d left join lease_agents a on a.id = d.agent_id), '[]'::jsonb);
end;
$$;
revoke all on function lease_signing_staff_list() from public, anon;
grant execute on function lease_signing_staff_list() to authenticated;
