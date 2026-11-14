revoke all on function mirror.clothing_label(text), mirror.laundry_days(uuid), mirror.clothing_suggested(text, int), mirror.clothing_inventory_category(text),
  mirror.clothing_size_key(text) from public, anon, authenticated;
grant execute on function mirror.clothing_label(text), mirror.laundry_days(uuid), mirror.clothing_suggested(text, int), mirror.clothing_inventory_category(text),
  mirror.clothing_size_key(text) to service_role;
revoke all on function public.mirror_clothing_get(uuid), public.mirror_clothing_save(jsonb, uuid) from public, anon;
grant execute on function public.mirror_clothing_get(uuid), public.mirror_clothing_save(jsonb, uuid) to authenticated, service_role;
