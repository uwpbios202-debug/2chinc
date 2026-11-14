revoke all on function mirror.adults_only(), mirror.hide_individual(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function mirror.hide_individual(uuid, uuid, text, text) to service_role;
revoke all on function public.mirror_my_hide(), public.mirror_my_unhide(), public.mirror_person_hide(uuid, uuid, text, boolean),
  public.mirror_platform_hide(text, boolean, text, boolean), public.mirror_notice_seen(text), public.mirror_admin_change_notice_set(text, date) from public, anon;
grant execute on function public.mirror_my_hide(), public.mirror_my_unhide(), public.mirror_person_hide(uuid, uuid, text, boolean),
  public.mirror_platform_hide(text, boolean, text, boolean), public.mirror_notice_seen(text), public.mirror_admin_change_notice_set(text, date)
  to authenticated, service_role;
