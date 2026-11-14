-- LOCAL ONLY (gitignored, never commit): real people's published emails for the CHPMS directory v2.
update chpms_orgs set general_email = replace(general_email, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where general_email like '%[named contact email kept at the office 1]%';
update chpms_orgs set verification_notes = replace(verification_notes, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where verification_notes like '%[named contact email kept at the office 1]%';
update chpms_orgs set main_phone = replace(main_phone, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where main_phone like '%[named contact email kept at the office 1]%';
update chpms_programs set how_to_apply = replace(how_to_apply, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where how_to_apply like '%[named contact email kept at the office 1]%';
update chpms_programs set notes = replace(notes, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where notes like '%[named contact email kept at the office 1]%';
update chpms_programs set intake_phone = replace(intake_phone, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where intake_phone like '%[named contact email kept at the office 1]%';
update chpms_programs set application_method = replace(application_method, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where application_method like '%[named contact email kept at the office 1]%';
update chpms_contacts set email = replace(email, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where email like '%[named contact email kept at the office 1]%';
update chpms_contacts set phone = replace(phone, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where phone like '%[named contact email kept at the office 1]%';
update chpms_checks set notes = replace(notes, '[named contact email kept at the office 1]', 'cshana@milwaukee.gov') where notes like '%[named contact email kept at the office 1]%';
