-- Cigarette and incense burns (Stephen, 10/31/2026): tenants are charged for them, so the tenant's own move-in checklist (also used for the
-- move-out comparison) now asks about them explicitly, in the places they usually show up. A room can carry its own condition words:
-- here "None found" (saved as good) and "Found" (saved as damaged, which already requires a description). The server check
-- move_in_checklist_problem() needs no change: every item still has to be answered and "damaged" needs a note.
update portal_settings
   set value = (value::jsonb || '[{"key": "burns", "name": "Burn marks (cigarette and incense)",
     "note": "You can be charged for cigarette and incense burns that are not listed here. Look closely: incense sticks leave tiny holes and burns in walls and around outlet and light switch covers; cigarette burns are usually on the bathroom sink and sometimes the floor. If you find one, choose Found and say where.",
     "conds": [["good", "None found"], ["damaged", "Found"]],
     "items": ["Incense burns or small holes in the walls", "Burn marks around outlet and light switch covers", "Cigarette burns on the bathroom sink", "Cigarette burns on the floors", "Any other cigarette or incense burn in the unit"]}]'::jsonb)::text
 where key = 'move_in_rooms' and value not like '%"key": "burns"%' and value not like '%"key":"burns"%';
