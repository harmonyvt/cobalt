-- Clip prep learns a new decoder (APP-API-CONTRACT.md section 51.2). Additive: one column.
-- Apply before the API deploy. Old code does not read the column. A row from before this
-- migration has prep_rev 0, so a failed prep is tried again on the new path. The attempt
-- cap and the day-long wait are unchanged.

ALTER TABLE media_safety ADD COLUMN prep_rev INTEGER NOT NULL DEFAULT 0;
