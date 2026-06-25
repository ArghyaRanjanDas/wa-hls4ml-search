# wa-hls4ml-search

Scripts to run large-scale hls4ml conversion and synthesis jobs to generate training data for the wa-hls4ml surrogate model.

Two backends are supported:
- **Catapult HLS (ASIC)** on Perlmutter (NERSC) — Nangate 45nm and GF22FDX targets. See [Catapult/Perlmutter flow](#catapultperlmutter-asic-flow) below.
- **Vivado HLS (FPGA)** on k8s or SLURM clusters — original flow, described in the [k8s/Vivado overview](#overview).

---

## Catapult/Perlmutter ASIC flow

Synthesis is driven by **GNU parallel** orchestrators in `slurm/examples/`. Each job spawns
3 SLURM nodes × 100 parallel Catapult instances (300 total = all available licenses), retries
failures automatically with `--resume-failed`, and archives results flat to the shared CFS directory.

### Prerequisites
- Catapult 2026.1 installed under `$SCRATCH/cad/Siemens/Catapult/2026.1_1/`
- `$SCRATCH/venv_hls4ml/` Python venv (or set `WA_HLS4ML_VENV`)
- `license_servers_perlmutter.json` at repo root (copy from `.example`)

### Quick reference

| What | Command |
|---|---|
| 45nm sz128 extension (1–3 layers) | `N_LAYERS=2 sbatch slurm/examples/submit_45nm_sz128.sh` |
| 45nm deep networks (4+ layers) | `N_LAYERS=4 sbatch slurm/examples/submit_45nm_nlayer_lhs.sh` |
| GF22nm 1-layer cartesian | `sbatch slurm/examples/run_dense_1layer_gf22_cartesian.sh` |
| GF22nm N-layer LHS | `N_LAYERS=3 sbatch slurm/examples/submit_gf22_nlayer_lhs.sh` |
| Archive a completed run | `bash slurm/examples/archive_run.sh <RUN_DIR>` |
| Check synthesis failures | `bash slurm/examples/check_failures.sh <RUN_DIR>` |
| Monitor jobs + resources | `bash check_progress_resources.sh` |

> **RF=1 with 128-neuron layers** requires longer wall time than the default `express_amsc` (6h).
> Override with: `SLURM_TIME=1-22:00:00 SLURM_QOS=regular N_LAYERS=2 sbatch submit_45nm_sz128.sh`

Results are archived to `/global/cfs/cdirs/amsc011/shared/wa-hls4ml-catapult/` (see `README.md` there).

See `slurm/README.md` for the full script inventory and how a synthesis task flows.

---

## Overview
The standard flow for running a large scale generation & synthesis job is as follows:

* Determine the parameter space that you would like to scan over for model architectures and quantization schemes
* Generate a configuration file specifying the models to be converted and synthesized
  * If running on k8s, you also must commit the model config files to a git repository that is accessible from the k8s cluster (for example, your fork of this github repository) and configure your job to clone the repo and use those config files. 
* Split that model config file into multiple smaller config files so that each job only processes a subset of the models
  * Use the provided [config splitting script](util/pregen_filelist_split.py) to do this
* Generate a k8s job yaml file OR a HPRC Script (for SLURM based clusters) for the configuration file with some conversion/search parameters set in this file
  * The recommended way to generate a k8s job yaml file is to create a "template" config file with the common parameters set, and then use a script to generate multiple job yaml files with different model subsets (see [this template](kube/wa-hls4ml-search-job-template-2layer-2023.yml) and [this script](kube/scripts/create_parallel_2layer_pregen_jobs.sh) for examples)
* Submit the jobs to the cluster (adhering to any cluster specific submission requirements/policies)
  * If using k8s and following the recommended approach of generating multiple job yaml files, it's also reccomended to use a script to submit/kill all the generated job yaml files (see [this script](kube/scripts/launch_parallel_2layer_pregen_jobs.sh) for an example)
* Collect the results from the cluster and aggregate them into a single results file for training the surrogate model
  * Use the provided [results aggregation script](util/json_dataset_merge.py) to do this
* Collect the generated projects for further analysis or use
  * If you plan on uploading the models to a service such as HuggingFace, it's recommended to "batch" the project files before uploading, primarily due to file count limits on such services. Use the provided [project batching script](util/batch_compress_files.py) to do this.


## Model Config File Generation
The model config files used to specify the models to be converted and synthesized are in JSON format. To generate these files, you can use the [gen_models script](gen_models.py) in the directory. This script allows you to define the architecture parameters, quantization schemes, and other relevant settings for the models you wish to include in your experiments.

At the moment, the way to configure the generation parameters is to modify the default values in the script itself. Future versions may include a more user-friendly way to specify these parameters via command line arguments or configuration files.

Documentation for the gen_models script can be found in [gen_models_documentation.md](gen_models_documentation.md).

## Requirements

* Python 3.10 conda environment created using the `environment.yml` file in this repository
  * If using the provided docker container, this is already set up for you
* Access to a k8s cluster OR a SLURM based cluster with the ability to submit jobs 
* An installation of Vivado 2023.2 or 2024.2 available on the cluster. 
  * This can either be as a module on a SLURM cluster (installed by cluster admins typically)
  * Or as part of a docker image + volume mount with the tools installed on a k8s cluster, this repository includes a Dockerfile that can be used to build an image for use with Vivado 2023.2 (see [The docker readme](/docker/README.md) on how to build the image, or use the one built by the github action in this repository).
  * 2020.1 is also included for historical purposes, but not recommended for new experiments and considered deprecated.