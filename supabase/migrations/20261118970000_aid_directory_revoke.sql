-- The aid directory is read and written only through security definer functions (aid_directory, aid_org_save, aid_program_save, aid_delete).
-- Default privileges had granted the website roles direct table access; take it back (row security already blocked it).
revoke all on aid_orgs, aid_programs from anon, authenticated;
