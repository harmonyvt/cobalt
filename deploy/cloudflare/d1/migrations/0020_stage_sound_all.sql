-- Stage (APP-API-CONTRACT.md section 30.2): two canvas switches. Additive only: apply this BEFORE deploying the
-- API Worker (old code never reads the new columns; new code reads them on every stage request).
--   sound_all:    every playing video tile has sound on stream, not only the spotlight (still under `sound`).
--   play_through: a playing video tile stays until it has played to its end once, even past its tile life.
ALTER TABLE stage_settings ADD COLUMN sound_all INTEGER NOT NULL DEFAULT 0;
ALTER TABLE stage_settings ADD COLUMN play_through INTEGER NOT NULL DEFAULT 0;
