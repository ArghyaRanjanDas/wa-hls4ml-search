"""SLURM job array submission for the wa-hls4ml-search Catapult flow.

This package wraps the SLURM-specific orchestration that was extracted from
iter_manager_catapult.py. The synthesis backend (catapult_shell.sh, model
generation, report collection) lives in the parent module — only the
job-array submission and CLI flags live here.

Public API:
    from slurm import job_array, cli
    slurm_cli.add_slurm_args(parser)
    job_array.submit(args, run_dir, joblist_path, job_lines, total_licenses,
                     lm_license_file)
"""
