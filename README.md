# MolPol FADC Analysis Scripts

This is a repository that will hold work for the HA Moller Polarimeter (MolPol) FADC Analysis and MolPol Data Management. All scripting projects will be kept in their own directory and content should be regarded as working examples. Nothing contained herein should be construed as official analysis. Main directory should only contain this README.md file.

## FADC Data Web Dashboard

The FADC Data Web Dashboard is a **separate project**. It is more actively maintained than the scripts in this repository and must be pulled independently when it is updated.

- Repository: https://github.com/dericking/molpol-fadc-analysis-dashboard

## Contents of Repository

### EPICS-table-snapshotter

Writer that fills `hamoller_db.EPICS_data` with a per-run snapshot of EPICS PVs from the JLab MYA archiver. The dashboard stays read-only; this project is the insert path.

See [`EPICS-table-snapshotter/README.md`](EPICS-table-snapshotter/README.md).

