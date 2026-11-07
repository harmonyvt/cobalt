-- Why a safety clip was not cut (APP-API-CONTRACT.md section 51.2). Additive: one nullable column.
-- Apply before the API deploy. Old code does not read it. A row from before this migration has
-- prep_error NULL. The attempt cap, the day-long wait, and SAFETY_BACKFILL are unchanged.

ALTER TABLE media_safety ADD COLUMN prep_error TEXT;
