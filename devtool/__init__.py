"""devtool — host-side CLI behind `run.py`: the environment/service picker, stop/list/logs/
build-base, the whitelist-proxy manager, and one-time host setup. Pure Python 3 stdlib, no
pip install. Not meant to be pip-installed itself — `run.py` at the repo root imports it
directly off `sys.path[0]`.
"""
