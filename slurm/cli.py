"""Argparse group for the SLURM job array submission flags.

Used by iter_manager_catapult.py to add --slurm and friends to its parser.
Defaults match Giuseppe's recommended Perlmutter setup for AmSC users.
"""


def add_slurm_args(parser):
    """Add --slurm* + --collect-slurm flags to an argparse parser.

    Args:
        parser: argparse.ArgumentParser instance to extend.
    """
    parser.add_argument(
        '--slurm', action='store_true', default=False,
        help='Use SLURM job array instead of GNU parallel',
    )
    parser.add_argument(
        '--slurm-account', type=str, default='amsc011',
        help='NERSC project account (default: amsc011)',
    )
    parser.add_argument(
        '--slurm-time', type=str, default='02:00:00',
        help='Walltime per task (default: 02:00:00)',
    )
    parser.add_argument(
        '--slurm-qos', type=str, default='express_amsc',
        help='SLURM QOS (default: express_amsc; '
             'options: debug, regular, shared, premium, express_amsc)',
    )
    parser.add_argument(
        '--slurm-constraint', type=str, default='cpu',
        help='Node constraint (default: cpu)',
    )
    parser.add_argument(
        '--collect-slurm', type=str, default=None, metavar='RUN_DIR',
        help='Skip synthesis, collect reports from a completed SLURM run',
    )
