-- Apply EPICS_data changes from don_set_up_mariadb.proposed.sh
-- to an existing hamoller_db (CREATE TABLE IF NOT EXISTS will not do this).
--
-- Safe if rows already exist: CHANGE keeps Hall A pass values; new columns
-- are NULL until the insert script fills them.
--
-- Before running: confirm the live name is still epics_n_pass
--   SHOW COLUMNS FROM hamoller_db.EPICS_data LIKE 'epics_n_pass%';
--   SHOW COLUMNS FROM hamoller_db.EPICS_data LIKE 'epics_mol_lock';
--   SHOW COLUMNS FROM hamoller_db.EPICS_data LIKE 'epics_mcz1h0h_cur';

USE hamoller_db;

-- 1. Rename Hall A pass (preserves existing values and comment/PV)
ALTER TABLE EPICS_data
    CHANGE COLUMN epics_n_pass epics_n_pass_halla VARCHAR(255)
        DEFAULT NULL COMMENT 'Passes Hall A [PV: MMSHLAPASS]';

-- 2. Add Hall B/C/D passes and accelerator PVs after Hall A pass
ALTER TABLE EPICS_data
    ADD COLUMN epics_n_pass_hallb VARCHAR(255)
        DEFAULT NULL COMMENT 'Passes Hall B [PV: MMSHLBPASS]'
        AFTER epics_n_pass_halla,
    ADD COLUMN epics_n_pass_hallc VARCHAR(255)
        DEFAULT NULL COMMENT 'Passes Hall C [PV: MMSHLCPASS]'
        AFTER epics_n_pass_hallb,
    ADD COLUMN epics_n_pass_halld VARCHAR(255)
        DEFAULT NULL COMMENT 'Passes Hall D [PV: MMSHLDPASS]'
        AFTER epics_n_pass_hallc,
    ADD COLUMN epics_ha_rf_freq FLOAT(10,5)
        DEFAULT NULL COMMENT 'HA RF frequency, MHz [PV: pgunFreqDiv:A:frequencyVal]'
        AFTER epics_n_pass_halld,
    ADD COLUMN epics_gun_kV FLOAT(10,5)
        DEFAULT NULL COMMENT 'Injector gun voltage, kV [PV: IGL0I00HVPSkVolts]'
        AFTER epics_ha_rf_freq,
    ADD COLUMN epics_inj_spot_x FLOAT(10,5)
        DEFAULT NULL COMMENT 'Injector spot x-position [PV: psub_cx_pos]'
        AFTER epics_gun_kV,
    ADD COLUMN epics_inj_spot_y FLOAT(10,5)
        DEFAULT NULL COMMENT 'Injector spot y-position [PV: psub_cy_pos]'
        AFTER epics_inj_spot_x;

-- 3. Beamline lock after the last BPM
ALTER TABLE EPICS_data
    ADD COLUMN epics_mol_lock TINYINT(1)
        DEFAULT NULL COMMENT 'HA Moller beam position lock On=1 Off=0 [PV: HallAMolLock:Onoff]'
        AFTER epics_bpm02a_Y;

-- 4. Horizontal corrector after the vertical corrector
ALTER TABLE EPICS_data
    ADD COLUMN epics_mcz1h0h_cur FLOAT(10,5)
        DEFAULT NULL COMMENT 'MCZ1H04 horizontal corrector [PV: MBD1H04HM]'
        AFTER epics_mcz1h0v_cur;

-- Verify
SHOW COLUMNS FROM EPICS_data
    WHERE Field IN (
        'epics_n_pass',
        'epics_n_pass_halla',
        'epics_n_pass_hallb',
        'epics_n_pass_hallc',
        'epics_n_pass_halld',
        'epics_ha_rf_freq',
        'epics_gun_kV',
        'epics_inj_spot_x',
        'epics_inj_spot_y',
        'epics_mol_lock',
        'epics_mcz1h0h_cur'
    );
