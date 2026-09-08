    #!/usr/bin/env bash
#######################################################
## Author: Donald Jones Aug. 2026 (Gemini 3.6 Flash) ##
## Property of Jefferson Lab                         ##
##                                                   ##
## This is the original script for setting up the    ##
## MariaDB SQL databases for the new FADC-based DAQ. ##
#######################################################

# EPICS_data proposal for Don (Sep 2026). Source: don_set_up_mariadb.original.sh
# from https://github.com/JeffersonLab/hamoller_analysis_tools
# Only EPICS_data changed. DAQ_config left as-is (not final).
#   - Rename epics_n_pass -> epics_n_pass_halla; add hallb/c/d
#   - Accelerator: epics_ha_rf_freq, epics_gun_kV, epics_inj_spot_x/y
#   - After BPMs: -- Beamline Locks (epics_mol_lock)
#   - After vertical corrector: epics_mcz1h0h_cur
# If hamoller already has rows, apply schema/alter_epics_data.proposed.sql
# (CHANGE epics_n_pass -> epics_n_pass_halla, then ADD the new columns).


# Exit immediately if a command exits with a non-zero status
set -eo pipefail

# Enable alias expansion within non-interactive bash scripts
shopt -s expand_aliases

# Source alias definitions from bashrc/bash_profile if available
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
elif [ -f ~/.bash_profile ]; then
    source ~/.bash_profile
fi
set -u
# --- SQL Script Definition ---
SQL_SCRIPT=$(cat <<'EOF'
USE hamoller_db;
-- Lookup table for Run Types
CREATE TABLE IF NOT EXISTS run_type_lookup (
    code VARCHAR(32) PRIMARY KEY,
    display_label VARCHAR(64) NOT NULL
);

INSERT IGNORE INTO run_type_lookup (code, display_label) VALUES
    ('RATE_SCAN',       'Rate scan'),
    ('POLARIZATION',    'Polarization'),
    ('SYSTEMATIC_STUDY','Systematic study'),
    ('BLEEDTHROUGH',    'Bleedthrough'),
    ('GAIN_MATCHING',   'Gain matching'),
    ('THRESHOLD_CHECK', 'Threshold check'),
    ('TEST',            'Test'),
    ('OTHER',           'Other');

-- Lookup table for Run Quality
CREATE TABLE IF NOT EXISTS run_quality_lookup (
    code VARCHAR(32) PRIMARY KEY,
    display_label VARCHAR(64) NOT NULL
);

INSERT IGNORE INTO run_quality_lookup (code, display_label) VALUES
    ('GOOD',         'Good'),
    ('BAD',          'Bad'),
    ('SUSPECT',      'Suspect'),
    ('JUNK',         'Junk'),
    ('UNDETERMINED', 'Undetermined');

-- 1. Run_info Table
CREATE TABLE IF NOT EXISTS Run_info (
    run_number 	    	   INT UNSIGNED PRIMARY KEY,
    run_group 	    	   INT UNSIGNED,
    run_experiment  	   VARCHAR(255) COMMENT 'Name of experiment',
    run_start_datetime 	   VARCHAR(50) COMMENT "Start of run time stamp -- fits Linux date default string (e.g., Fri Jul 31 16:54:21 EDT 2026)",
    run_end_datetime 	   VARCHAR(50)COMMENT 'End of run time stamp -- fits Linux date default string (e.g., Fri Jul 31 16:54:21 EDT 2026)',
    run_start_unix 	   INT UNSIGNED COMMENT 'Start of run Unix time in seconds',
    run_end_unix 	   INT UNSIGNED COMMENT 'End of run Unix time in seconds',
    run_length             INT UNSIGNED NULL COMMENT 'Run length in seconds',
 
    -- Lookup fields with fixed options
    run_type     VARCHAR(32) NOT NULL DEFAULT 'OTHER',
    run_quality  VARCHAR(32) NOT NULL DEFAULT 'UNDETERMINED',

    -- Foreign Key constraints to enforce valid values
    CONSTRAINT fk_run_info_type 
        FOREIGN KEY (run_type) 
        REFERENCES run_type_lookup(code)
        ON UPDATE CASCADE 
        ON DELETE RESTRICT,

    CONSTRAINT fk_run_info_quality 
        FOREIGN KEY (run_quality) 
        REFERENCES run_quality_lookup(code)
        ON UPDATE CASCADE 
        ON DELETE RESTRICT,
        
     -- Trigger Prescales
    trig_ps1 INT COMMENT 'Trigger 1 MPS prescale: -1 disabled, 0 no prescale, 1 keep every other event, 2 keep every 3rd event',
    trig_ps2 INT COMMENT 'Trigger 2 prescale: -1 disabled, 0 no prescale, 1 keep every other event, 2 keep every 3rd event',
    trig_ps3 INT COMMENT 'Trigger 3 Leftsum prescale: -1 disabled, 0 no prescale, 1 keep every other event, 2 keep every 3rd event',
    trig_ps4 INT COMMENT 'Trigger 4 Rightsum prescale: -1 disabled, 0 no prescale, 1 keep every other event, 2 keep every 3rd event',
    trig_ps5 INT COMMENT 'Trigger 5 prescale: -1 disabled, 0 no prescale, 1 keep every other event, 2 keep every 3rd event',
    trig_ps6 INT COMMENT 'Trigger 6 Coinc prescale: -1 disable, 0 no prescale, 1 keep every other event, 2 keep every 3rd event',

    -- Beam and Target 
    beam_sigma_x 	       FLOAT(10,5) COMMENT '1 sigma x-width (mm) of beam from harp scan',
    beam_sigma_y 	       FLOAT(10,5) COMMENT '1 sigma y-width (mm) of beam from harp scan',
    requested_current 	   FLOAT(10,5) COMMENT 'Requested beam current in microamperes',
    target_pol 		       FLOAT(10,8) COMMENT 'Calculated target polarization',
    target_foil_avgT 	   FLOAT(10,5) COMMENT 'Foil temperature in Kelvin weighted by beam intensity',
    
    comment 		       TEXT,
    last_updated 	       TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP 
        		               COMMENT 'Timestamp of last record update'
) ENGINE=InnoDB;

-- 2. DAQ_config Table
CREATE TABLE IF NOT EXISTS DAQ_config (
    run_number INT UNSIGNED PRIMARY KEY,
    block_level   SMALLINT,
    buffer_level  SMALLINT,
    
    -- Crate & Slot Identification 
    fadc_crate    VARCHAR(255) DEFAULT NULL COMMENT 'Crate identifier or hostname (e.g., all, hapolmollervme.jlab.org)', 
    fadc_slot     VARCHAR(255) DEFAULT NULL COMMENT 'Slot selection (e.g., all, 3)', 

    -- Channel Masks & Operating Modes 
    fadc_adc_mask        VARCHAR(255) DEFAULT NULL COMMENT 'ADC channel enable mask', 
    fadc_allch_mode      VARCHAR(255) DEFAULT NULL COMMENT 'FADC mode for each channel', 
    fadc_mode            VARCHAR(255) DEFAULT NULL COMMENT 'FADC mode set if equal for all channels', 


    -- Windowing & Timing Definitions 
    fadc_allch_w_offset  VARCHAR(255) DEFAULT NULL COMMENT 'Number of ns back from trigger point set channel by channel', 
    fadc_allch_w_width   VARCHAR(255) DEFAULT NULL COMMENT 'Number of ns to include in trigger window set channel by channel',	
    fadc_allch_nsb       VARCHAR(255) DEFAULT NULL COMMENT 'Time (units: ns) before threshold crossing to include in integral set channel by channel', 
    fadc_allch_nsa       VARCHAR(255) DEFAULT NULL COMMENT 'Time (units: ns) after threshold crossing to include in integral set channel by channel', 
    fadc_w_offset  SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Number of ns back from trigger point set if equal for all channels', 
    fadc_w_width   SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Number of ns to include in trigger window set if equal for all channels', 
    fadc_nsb       SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Time (units: ns) before threshold crossing to include in integral set if equal for all channels', 
    fadc_nsa       SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Time (units: ns) after threshold crossing to include in integral set if equal for all channels', 


    -- Peak Processing & Pedestal Limits 
    fadc_allch_npeak    VARCHAR(255) DEFAULT NULL COMMENT 'Max number of pulses allowed for each window set channel by channel', 
    fadc_allch_nped     VARCHAR(255) DEFAULT NULL COMMENT 'Number of samples included in pedestal sum set channel by channel', 
    fadc_allch_maxped   VARCHAR(255) DEFAULT NULL COMMENT 'Maximum value of sample to be included in pedestal sum (0--1023) set channel by channel', 
    fadc_allch_nsat     VARCHAR(255) DEFAULT NULL COMMENT 'Min number of consecutive samples over threshold for valid pulse (1--4) set channel by channel', 
    fadc_npeak   SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Max number of pulses allowed for each window set when all channels the same, otherwise -1', 
    fadc_nped    SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Number of samples to be included in pedestal sum set when all channels the same, otherwise -1', 
    fadc_maxped  SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Max value of sample to be included in pedestal sum (0--1023)set when all channels the same, otherwise -1', 
    fadc_nsat    SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Min number of consecutive samples over threshold for valid pulse (1--4) set when all channels the same, otherwise -1', 

    -- DAC, Gain & Accumulator Configuration
    fadc_allch_dac                     VARCHAR(255) DEFAULT NULL COMMENT 'Board DAC set channel by channel (DAC/mB)',
    fadc_dac                           SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Board DAC set when all 16 channels the same, otherwise -1 (DAC/mV)', 
    fadc_allch_gain                    VARCHAR(255) DEFAULT NULL COMMENT 'Board Gains set channel by channel (MeV/channel)', 
    fadc_gain                          FLOAT(10,5) DEFAULT NULL COMMENT 'Board Gains set when all channels equal, otherwise -1 (MeV/channel)', 

    -- Møller Discriminator & Trigger Logic Settings 
    fadc_l_offset   FLOAT(10,5) COMMENT 'ADC amplitude subtracted from the sum of the 4 left channels i.e. the sum pedestal', 
    fadc_r_offset   FLOAT(10,5) COMMENT 'ADC amplitude subtracted from the sum of the 4 right channels i.e. the sum pedestal', 
    fadc_disc_width FLOAT(10,5) COMMENT 'Coincidence with in 4ns units (the left/right sum discriminator width)', 
    fadc_disc_mode  TINYINT(1) COMMENT 'When 0 the left/right sum discriminators are operating in non-updating mode', 
    fadc_l_sum_thr  FLOAT(10,5) COMMENT 'Threshold which the left sum must pass', 
    fadc_r_sum_thr  FLOAT(10,5) COMMENT 'Threshold which the right sum must pass', 
    fadc_trg_sel    TINYINT(1) DEFAULT NULL COMMENT '0=multiplicity, 1=moller-AND, 2=moller-OR', 
    fadc_trg_width  SMALLINT UNSIGNED DEFAULT NULL COMMENT 'Stretches pulse width of channel over threshold in 4ns ticks for TI input', 

    -- Pedestal & Channel Threshold
    fadc_allch_ped   TEXT DEFAULT NULL COMMENT 'Pedestal values for all 16 channels', 
    fadc_ped         TEXT DEFAULT NULL COMMENT 'Pedestal value set when same for all 16 channels, otherwise -1', 
    fadc_allch_tet   VARCHAR(255) DEFAULT NULL COMMENT 'Specific channel hit threshold override setting', 
    fadc_tet         VARCHAR(255) DEFAULT NULL COMMENT 'Channel hit threshold set when same for all 16 channels, otherwise -1', 


    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP 
        COMMENT 'Timestamp of last record update',
    
    CONSTRAINT fk_daq_run FOREIGN KEY (run_number) 
        REFERENCES Run_info(run_number)
) ENGINE=InnoDB;

-- 3. EPICS_data Table
CREATE TABLE IF NOT EXISTS EPICS_data (
    run_number               INT UNSIGNED PRIMARY KEY,
    
    -- Accelerator & Beam Energy
    epics_E_beam             FLOAT(10,5) DEFAULT NULL COMMENT 'Beam energy, MeV Hall A [PV: HALLA:p]',
    epics_E_inj              FLOAT(10,5) DEFAULT NULL COMMENT 'Injector energy, MeV [PV: MMSINJEGAIN]',
    epics_E_Slinac           FLOAT(10,5) DEFAULT NULL COMMENT 'South linac energy, MeV [PV: MMSLIN1EGAIN]',
    epics_E_Nlinac           FLOAT(10,5) DEFAULT NULL COMMENT 'North linac energy, MeV [PV: MMSLIN2EGAIN]',
    epics_n_pass_halla       VARCHAR(255) DEFAULT NULL COMMENT 'Passes Hall A [PV: MMSHLAPASS]',
    epics_n_pass_hallb       VARCHAR(255) DEFAULT NULL COMMENT 'Passes Hall B [PV: MMSHLBPASS]',
    epics_n_pass_hallc       VARCHAR(255) DEFAULT NULL COMMENT 'Passes Hall C [PV: MMSHLCPASS]',
    epics_n_pass_halld       VARCHAR(255) DEFAULT NULL COMMENT 'Passes Hall D [PV: MMSHLDPASS]',
    epics_ha_rf_freq         FLOAT(10,5) DEFAULT NULL COMMENT 'HA RF frequency, MHz [PV: pgunFreqDiv:A:frequencyVal]',
    epics_gun_kV             FLOAT(10,5) DEFAULT NULL COMMENT 'Injector gun voltage, kV [PV: IGL0I00HVPSkVolts]',
    epics_inj_spot_x         FLOAT(10,5) DEFAULT NULL COMMENT 'Injector spot x-position [PV: psub_cx_pos]',
    epics_inj_spot_y         FLOAT(10,5) DEFAULT NULL COMMENT 'Injector spot y-position [PV: psub_cy_pos]',

    -- Beam Current Monitors (BCMs) & Unsers
    epics_bcm_avg            FLOAT(10,7) DEFAULT NULL COMMENT 'Beam Current Average [PV: hac_bcm_average]',
    epics_unser              FLOAT(10,7) DEFAULT NULL COMMENT 'Current on Unser monitor [PV: hac_unser_read]',
    epics_bcm_us             FLOAT(10,7) DEFAULT NULL COMMENT 'Current on Upstream bcm [PV: hac_bcm_dvm1_current]',
    epics_bcm_ds             FLOAT(10,7) DEFAULT NULL COMMENT 'Current on Downstream bcm [PV: hac_bcm_dvm2_current]',
    epics_inj_bcm_tot        FLOAT(10,7) DEFAULT NULL COMMENT 'Injector Full Current Monitor 02 [PV: IBC0L02Current]',
    epics_inj_bcm_halla      FLOAT(10,7) DEFAULT NULL COMMENT 'Injector Current Monitor Hall A [PV: IBC1H04CRCUR2]',
    epics_bcm_a1_coeff       FLOAT(10,5) DEFAULT NULL COMMENT 'Upstream Cavity Coefficient [PV: hac_bcm_A1]',
    epics_bcm_a2_coeff       FLOAT(10,5) DEFAULT NULL COMMENT 'Downstream Cavity Coefficient [PV: hac_bcm_A2]',

    -- Beam Position Monitors (BPMs)
    epics_bpm01_X            FLOAT(10,8) DEFAULT NULL COMMENT 'Beam Position BPM01 X, mm [PV: IPM1H01.XPOS]',
    epics_bpm01_Y            FLOAT(10,8) DEFAULT NULL COMMENT 'Beam Position BPM01 Y, mm [PV: IPM1H01.YPOS]',
    epics_bpm04_X            FLOAT(10,8) DEFAULT NULL COMMENT 'Beam Position BPM04 X, mm [PV: IPM1H04.XPOS]',
    epics_bpm04_Y            FLOAT(10,8) DEFAULT NULL COMMENT 'Beam Position BPM04 Y, mm [PV: IPM1H04.YPOS]',
    epics_bpm04a_X           FLOAT(10,8) DEFAULT NULL COMMENT 'Beam Position BPM04A X, mm [PV: IPM1H04A.XPOS]',
    epics_bpm04a_Y           FLOAT(10,8) DEFAULT NULL COMMENT 'Beam Position BPM04A Y, mm [PV: IPM1H04A.YPOS]',
    epics_bpm02a_X           FLOAT(10,8) DEFAULT NULL COMMENT 'Beam Position BPM02A X, mm [PV: IPM1P02A.XPOS]',
    epics_bpm02a_Y           FLOAT(10,8) DEFAULT NULL COMMENT 'Beam Position BPM02A Y, mm [PV: IPM1P02A.YPOS]',

    -- Beamline Locks
    epics_mol_lock           TINYINT(1) DEFAULT NULL COMMENT 'HA Moller beam position lock On=1 Off=0 [PV: HallAMolLock:Onoff]',

    -- Beamline Magnets
    epics_q1_cur             FLOAT(10,5) DEFAULT NULL COMMENT 'Quad Q1 (Amps) [PV: MQO1H02M]',
    epics_q2_cur             FLOAT(10,5) DEFAULT NULL COMMENT 'Quad Q2 (Amps) [PV: MQM1H02M]',
    epics_q3_cur             FLOAT(10,5) DEFAULT NULL COMMENT 'Quad Q3 (Amps) [PV: MQO1H03M]',
    epics_q4_cur             FLOAT(10,5) DEFAULT NULL COMMENT 'Quad Q4 (Amps) [PV: MQO1H03AM]',
    epics_dip_cur            FLOAT(10,5) DEFAULT NULL COMMENT 'Dipole (Amps) [PV: MMA1H01M]',
    epics_mcz1h0v_cur        FLOAT(10,5) DEFAULT NULL COMMENT 'MCZ1H0V vertical corrector [PV: MBD1H04VM]',
    epics_mcz1h0h_cur        FLOAT(10,5) DEFAULT NULL COMMENT 'MCZ1H04 horizontal corrector [PV: MBD1H04HM]',

    -- Target System
    epics_tgt_foil           INT(11) DEFAULT NULL COMMENT 'Target selection ID / state',
    epics_tgt_angle          FLOAT(10,5) DEFAULT NULL COMMENT 'Target Rotary Position(V) [PV: HAHFMROTENC]',
    epics_tgt_rot_neglimit   TINYINT(1) DEFAULT NULL COMMENT 'Rotary Negative Limit Switch [PV: HAHFMROTSM.LLS]',
    epics_tgt_rot_poslimit   TINYINT(1) DEFAULT NULL COMMENT 'Rotary Positive Limit Switch [PV: HAHFMROTSM.HLS]',
    epics_tgt_rot_athome     TINYINT(1) DEFAULT NULL COMMENT 'Rotary Home(Center) Switch [PV: HAHFMROTSM.ATHM]',
    epics_tgt_angle_deg      FLOAT(10,5) DEFAULT NULL COMMENT 'Rotary Position in deg(from controller) [PV: HAHFMROTSM.RBV]',
    epics_tgt_lin_pos        FLOAT(10,5) DEFAULT NULL COMMENT 'Target Linear Position(V) [PV: HAHFMLINENC]',
    epics_tgt_lin_hlimit     TINYINT(1) DEFAULT NULL COMMENT 'Linear Extended Limit Switch [PV: HAHFMLINSM.HLS]',
    epics_tgt_lin_llmit      TINYINT(1) DEFAULT NULL COMMENT 'Linear Retracted Limit Switch [PV: HAHFMLINSM.LLS]',
    epics_tgt_lin_athome     TINYINT(1) DEFAULT NULL COMMENT 'Linear Home switch [PV: HAHFMLINSM.ATHM]',
    epics_tgt_lin_pos_mm     FLOAT(10,5) DEFAULT NULL COMMENT 'Linear Position in mm [PV: HAHFMLINSM.RBV]',
    epics_tgt_ladder_temp1   FLOAT(10,5) DEFAULT NULL COMMENT 'Hall A Moller target ladder temperature (degC) near foil 1 [PV: hamolpol_tgt_ladder_temp1]',
    epics_tgt_ladder_temp2   FLOAT(10,5) DEFAULT NULL COMMENT 'Hall A Moller target ladder temperature (degC) near foil 2 [PV: hamolpol_tgt_ladder_temp2]',
    epics_tgt_ladder_temp3   FLOAT(10,5) DEFAULT NULL COMMENT 'Hall A Moller target ladder temperature (degC) near foil 3 [PV: hamolpol_tgt_ladder_temp3]',
    epics_tgt_motion_temp    FLOAT(10,5) DEFAULT NULL COMMENT 'Hall A Moller temperature (degC) on linear motion housing [PV: hamolpol_tgt_lifter_temp]',
    epics_tgt_flange_temp    FLOAT(10,5) DEFAULT NULL COMMENT 'Hall A Moller top target magnet flange temperature (degC) [PV: hamolpol_tgt_top_flange_temp]',

    -- Injector Laser & Slits
    epics_las_mode_halla     VARCHAR(255) DEFAULT NULL COMMENT 'Laser mode Hall A [PV: IGL1I00HALLAMODE]',
    epics_las_mode_hallb     VARCHAR(255) DEFAULT NULL COMMENT 'Laser mode Hall B [PV: IGL1I00HALLBMODE]',
    epics_las_mode_hallc     VARCHAR(255) DEFAULT NULL COMMENT 'Laser mode Hall C [PV: IGL1I00HALLCMODE]',
    epics_las_mode_halld     VARCHAR(255) DEFAULT NULL COMMENT 'Laser mode Hall D [PV: IGL1I00HALLDMODE]',
    epics_las_pow_halla      FLOAT(10,5) DEFAULT NULL COMMENT 'Laser power Hall A [PV: IGL1I00AI3]',
    epics_las_pow_hallb      FLOAT(10,5) DEFAULT NULL COMMENT 'Laser power Hall B [PV: IGL1I00AI4]',
    epics_las_pow_hallc      FLOAT(10,5) DEFAULT NULL COMMENT 'Laser power Hall C [PV: IGL1I00AI5]',
    epics_las_pow_halld      FLOAT(10,5) DEFAULT NULL COMMENT 'Laser power Hall D [PV: IGL1I00AI6]',
    epics_las_attn_halla     FLOAT(10,5) DEFAULT NULL COMMENT 'Laser attenuation Hall A [PV: psub_aa_pos]',
    epics_las_attn_hallb     FLOAT(10,5) DEFAULT NULL COMMENT 'Laser attenuation Hall B [PV: psub_ab_pos]',
    epics_las_attn_hallc     FLOAT(10,5) DEFAULT NULL COMMENT 'Laser attenuation Hall C [PV: psub_ac_pos]',
    epics_las_attn_halld     FLOAT(10,5) DEFAULT NULL COMMENT 'Laser attenuation Hall D [PV: psub_ad_pos]',
    epics_slit_halla         FLOAT(10,5) DEFAULT NULL COMMENT 'Slit Position Hall A [PV: SMRPOSA]',
    epics_slit_hallb         FLOAT(10,5) DEFAULT NULL COMMENT 'Slit Position Hall B [PV: SMRPOSB]',
    epics_slit_hallc         FLOAT(10,5) DEFAULT NULL COMMENT 'Slit Position Hall C [PV: SMRPOSC]',
    epics_slit_halld         FLOAT(10,5) DEFAULT NULL COMMENT 'Slit Position Hall D [PV: SMRPOSD]',
    epics_pockels_v1         FLOAT(10,5) DEFAULT NULL COMMENT 'Pockels Cell Voltage 1 [PV: IGL1I00AI7]',
    epics_pockels_v2         FLOAT(10,5) DEFAULT NULL COMMENT 'Pockels Cell Voltage 2 [PV: IGL1I00AI8]',
    epics_las_a_rf_phase     FLOAT(10,5) DEFAULT NULL COMMENT 'Laser A RF phase degrees [PV: R0L1PMES]',
    epics_las_a_src_cur      FLOAT(10,5) DEFAULT NULL COMMENT 'Laser A source current uA [PV: enlk4A:floatspare1]',

    -- Polarization & Wien Filters / Waveplates
    epics_ihwp               VARCHAR(16) DEFAULT NULL COMMENT 'Laser 1/2 wave plate [PV: IGL1I00OD16_16]',
    epics_rhwp               FLOAT(10,5) DEFAULT NULL COMMENT 'Rotating 1/2 wave plate [PV: psub_pl_pos]',
    epics_vwien_bdl          FLOAT(10,5) DEFAULT NULL COMMENT 'VWien BdL [PV: MWF1I04.BDL]',
    epics_vwien_field        FLOAT(10,5) DEFAULT NULL COMMENT 'VWien field [PV: MWF1I04.S]',
    epics_vwien_angle        FLOAT(10,5) DEFAULT NULL COMMENT 'VWien filter angle, deg [PV: VWienAngle]',
    epics_sol_a_bdl          FLOAT(10,5) DEFAULT NULL COMMENT 'Solenoid A BdL [PV: MFG1I04A.BDL]',
    epics_sol_a_field        FLOAT(10,5) DEFAULT NULL COMMENT 'Solenoid A field [PV: MFG1I04A.S]',
    epics_sol_b_bdl          FLOAT(10,5) DEFAULT NULL COMMENT 'Solenoid B BdL [PV: MFG1I04B.BDL]',
    epics_sol_b_field        FLOAT(10,5) DEFAULT NULL COMMENT 'Solenoid B field [PV: MFG1I04B.S]',
    epics_sol_phi_fg         FLOAT(10,5) DEFAULT NULL COMMENT 'Solenoids angle, deg [PV: Phi_FG]',
    epics_hwien_bdl          FLOAT(10,5) DEFAULT NULL COMMENT 'HWien BdL [PV: MWF1I06.BDL]',
    epics_hwien_field        FLOAT(10,5) DEFAULT NULL COMMENT 'HWien field [PV: MWF1I06.S]',
    epics_hwien_angle        FLOAT(10,5) DEFAULT NULL COMMENT 'HWien filter angle, deg [PV: HWienAngle]',

    -- Helicity Board Settings
    epics_hel_pattern        VARCHAR(255) DEFAULT NULL COMMENT 'Helicity pattern pair, quartet, octet... [PV: HELPATTERNd]',
    epics_hel_freq           DECIMAL(12,8) DEFAULT NULL COMMENT 'Helicity flip frequency [PV: HELFREQ]',
    epics_hel_delay          VARCHAR(255) DEFAULT NULL COMMENT 'Helicity delay in units of windows [PV: HELDELAYd]',
    epics_t_settle           FLOAT(10,5) DEFAULT NULL COMMENT 'Tsettle window MPS signal, usec [PV: HELTSETTLEd]',
    epics_t_stable           FLOAT(10,5) DEFAULT NULL COMMENT 'Helicity Tstable window, usec [PV: HELTSTABLEd]',

    -- Superconducting Solenoid Magnet (Møller Polarimeter)
    epics_mol_pow_sup_cur    	FLOAT(10,5) DEFAULT NULL COMMENT 'AM430 Current Setpoint (A) [PV: hamolpol:am430:target]',
    epics_mol_mag_cur_set    	FLOAT(10,5) DEFAULT NULL COMMENT 'AM430 Current Setpoint Readback (A) [PV: hamolpol:am430:targetRbck]',
    epics_mol_mag_htr_ctrl   	FLOAT(10,5) DEFAULT NULL COMMENT 'AM430 Persistence Heater Control [PV: hamolpol:am430:turnOn]',
    epics_mol_mag_cur_meas   	FLOAT(10,5) DEFAULT NULL COMMENT 'AM430 Measured Current (A) [PV: hamolpol:am430:magCurrent]',
    epics_mol_mag_v_meas     	FLOAT(10,5) DEFAULT NULL COMMENT 'AM430 Measured Voltage (A) [PV: hamolpol:am430:magVoltage]',
    epics_mol_mag_field_meas 	FLOAT(10,5) DEFAULT NULL COMMENT 'AM430 Measured Field (T) [PV: hamolpol:am430:magField]',
    epics_mol_mag_ramp_state 	FLOAT(10,5) DEFAULT NULL COMMENT 'AMS430 Ramp State [PV: hamolpol:am430:rampState]',
    epics_mol_cooler_temp    	FLOAT(10,5) DEFAULT NULL COMMENT 'Cryocooler Temperature (K) [PV: hamolpol:lk218_1:temp1]',
    epics_mol_mag_T2temp     	FLOAT(10,5) DEFAULT NULL COMMENT 'Magnet(T2) Temperature(K) [PV: hamolpol:lk218_1:temp2]',
    epics_mol_mag_lead1_temp 	FLOAT(10,5) DEFAULT NULL COMMENT 'Magnet Lead #1 (T6) Temperature(K) [PV: hamolpol:lk218_1:temp6]',
    epics_mol_mag_lead2_temp 	FLOAT(10,5) DEFAULT NULL COMMENT 'Magnet Lead #2 (T7) Temperature(K) [PV: hamolpol:lk218_1:temp7]',
    epics_mol_ext_gaussmeter 	FLOAT(10,5) DEFAULT NULL COMMENT 'Magnet External Gaussmeter (kGs) [PV: hamolpol:lk450:fld]',

    -- Cryomech Compressor System
    epics_cryo_comp_op_time	FLOAT(10,5) DEFAULT NULL COMMENT 'Cryomech CP1110 Compressor Oper.Time (min) [PV: hamolpol:CP2800:compMins]',
    epics_cryo_water_in_temp 	FLOAT(10,5) DEFAULT NULL COMMENT 'Cryomech CP1110 Input Water Temp (C) [PV: hamolpol:CP2800:waterInTemp]',
    epics_cryo_water_out_temp 	FLOAT(10,5) DEFAULT NULL COMMENT 'Cryomech CP1110 Output Water Temp (C) [PV: hamolpol:CP2800:waterOutTemp]',
    epics_cryo_press_high    	FLOAT(10,5) DEFAULT NULL COMMENT 'Cryomech CP1110 High Side Pressure (PSI) [PV: hamolpol:CP2800:pressHigh]',
    epics_cryo_press_low     	FLOAT(10,5) DEFAULT NULL COMMENT 'Cryomech CP1110 Low Side Pressure (PSI) [PV: hamolpol:CP2800:pressLow]',

    -- Detector High Voltage Readbacks (Channels 1 - 8)
    epics_det_hv_ch1         FLOAT(10,5) DEFAULT NULL COMMENT 'HA Moller HV Readback Ch 1 (V) [PV: IHVHAPOL:03:000:VMon]',
    epics_det_hv_ch2         FLOAT(10,5) DEFAULT NULL COMMENT 'HA Moller HV Readback Ch 2 (V) [PV: IHVHAPOL:03:001:VMon]',
    epics_det_hv_ch3         FLOAT(10,5) DEFAULT NULL COMMENT 'HA Moller HV Readback Ch 3 (V) [PV: IHVHAPOL:03:002:VMon]',
    epics_det_hv_ch4         FLOAT(10,5) DEFAULT NULL COMMENT 'HA Moller HV Readback Ch 4 (V) [PV: IHVHAPOL:03:003:VMon]',
    epics_det_hv_ch5         FLOAT(10,5) DEFAULT NULL COMMENT 'HA Moller HV Readback Ch 5 (V) [PV: IHVHAPOL:03:004:VMon]',
    epics_det_hv_ch6         FLOAT(10,5) DEFAULT NULL COMMENT 'HA Moller HV Readback Ch 6 (V) [PV: IHVHAPOL:03:005:VMon]',
    epics_det_hv_ch7         FLOAT(10,5) DEFAULT NULL COMMENT 'HA Moller HV Readback Ch 7 (V) [PV: IHVHAPOL:03:006:VMon]',
    epics_det_hv_ch8         FLOAT(10,5) DEFAULT NULL COMMENT 'HA Moller HV Readback Ch 8 (V) [PV: IHVHAPOL:03:007:VMon]',
    last_updated 	         TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Timestamp of last record update',

    CONSTRAINT fk_epics_run FOREIGN KEY (run_number) 
        REFERENCES Run_info(run_number)
) ENGINE=InnoDB;

-- 4. Analysis Table
CREATE TABLE IF NOT EXISTS Analysis (
    run_number 	     INT UNSIGNED PRIMARY KEY,

    -- Event Rates & Scalers
    leftrate 	     FLOAT DEFAULT NULL COMMENT 'Left detector rate (Hz)',
    leftrate_err     FLOAT DEFAULT NULL COMMENT 'Error on left detector rate (Hz)',
    rightrate 	     FLOAT DEFAULT NULL COMMENT 'Right detector rate (Hz)',
    rightrate_err    FLOAT DEFAULT NULL COMMENT 'Error on right detector rate (Hz)',
    coinrate 	     FLOAT DEFAULT NULL COMMENT 'Coincidence rate (Hz)',
    coinrate_err     FLOAT DEFAULT NULL COMMENT 'Error on coincidence rate (Hz)',
    accrate 	     FLOAT DEFAULT NULL COMMENT 'Accidental coincidence rate (Hz)',
    accrate_err      FLOAT DEFAULT NULL COMMENT 'Error on accidental coincidence rate (Hz)',
    counts_to_Hz     FLOAT DEFAULT NULL COMMENT 'Multiplicative factor to get from counts per window to rate. Should be 1/T_settle.',	     

    -- Diagnostics & Timing
    bcm			        INT DEFAULT NULL COMMENT 'Beam current monitor scaler counts',
    clock100kHz      	INT  DEFAULT NULL COMMENT '100kHz Clock scaler ticks',
    clock20MHz       	INT  DEFAULT NULL COMMENT '20MHz Clock scaler ticks',
    deadtime_tau_1 	    DOUBLE COMMENT 'Dead time constant (s) for coinc-coinc pile up',
    deadtime_tau_2 	    DOUBLE COMMENT 'Dead time constant (s) for single-coinc pile up',
    accid_tau 	   	    DOUBLE COMMENT 'Accidental window width (s)',	       


    -- Asymmetries & Polarization Parameters
    asym_mol 	     	FLOAT DEFAULT NULL COMMENT 'Measured raw asymmetry',
    asym_mol_err     	FLOAT DEFAULT NULL COMMENT 'Statistical error on raw asymmetry',
    Azz 		        FLOAT(10,8) DEFAULT NULL COMMENT 'Analyzing power Azz',
    poltarg 	     	FLOAT(10,8) DEFAULT NULL COMMENT 'Target polarization',
    pol_beam 	     	FLOAT DEFAULT NULL COMMENT 'Extracted beam polarization',
    pol_beam_err     	FLOAT DEFAULT NULL COMMENT 'Error on beam polarization',

    -- Charge Asymmetry & Pedestals
    asym_q    		    FLOAT DEFAULT NULL COMMENT 'Charge asymmetry',
    asym_q_err 		    FLOAT DEFAULT NULL COMMENT 'Error on charge asymmetry',
    qpedused 		    FLOAT DEFAULT NULL COMMENT 'BCM pedestal value used in analysis',
    qpedcalc 		    FLOAT DEFAULT NULL COMMENT 'Calculated BCM pedestal value',

    last_updated 	    TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP 
        		            COMMENT 'Timestamp of last record update',
    
    CONSTRAINT fk_analysis_run FOREIGN KEY (run_number) 
        REFERENCES Run_info(run_number)
) ENGINE=InnoDB;

EOF
)

# --- Execution ---
echo "Connecting to hamoller_db via alias 'hamoller_sql_user'..."

# Execute SQL script using your alias
hamoller_sql_admin <<< "$SQL_SCRIPT"

echo "Database tables (Run_info, DAQ_config, EPICS_data, Analysis) successfully created!"
