-- LOCAL ONLY (listed in .gitignore; never commit): a real person's phone and address (CLAUDE.md rule).
-- First Navigator's contact details: phone from her 11/11/2026 voicemail; address = her registered agent / principal office on
-- the Wisconsin DFI record for Long Lasting Care LLC (L078074). She can correct both on her Profile tab.
update navigators
   set phone = coalesce(phone, '(414) 737-0590'),
       mailing_address = coalesce(mailing_address, '2840 W Mill Rd, Unit F, Milwaukee, WI 53209'),
       updated_at = now()
 where id = '72d0a47d-4936-4cf3-8f2d-14d40190fb82';
