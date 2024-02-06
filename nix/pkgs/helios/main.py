#! /usr/bin/env nix-shell
#! nix-shell -i python3 -p python311 python311Packages.colorama python311Packages.pillow python311Packages.flake8 python311Packages.gphoto2 python311Packages.pytest python311Packages.shellingham python311Packages.typer
# vi: ft=python

import typer
import os
from enum import Enum
from types import SimpleNamespace
import logging
from xdg import xdg_cache_home, xdg_state_home

import import_from


app = typer.Typer()
app.add_typer(import_from.app, name="import")


"""
Can take paramaters in order of higher precednece.
- cli flag
- env var
- default
"""


class LogLevel(str, Enum):
    debug = "DEBUG"
    info = "INFO"
    warning = "WARNING"
    error = "ERROR"
    crtical = "CRITICAL"


@app.callback()
def main(
    ctx: typer.Context,
    db_path: str = typer.Option(None, envvar="HELIOS_DB_PATH"),
    photo_dir: str = typer.Option(None, envvar="HELIOS_LIBRAY_PATH"),
    log_level: LogLevel = LogLevel.info,
):
    if not db_path:
        db_path = os.path.join(xdg_state_home(), "helios", "helios.db")
    if not photo_dir:
        photo_dir = os.path.join(os.path.expanduser("~"), "photos")

    # since I just need want a simple namespace with a single member, I used
    # SimpleNamespace. If this object grows and needs more members, I could use
    # dataclasses or attrs or pydantic, but all of those are overkill here.
    logging.basicConfig(
        format="%(levelname)s: %(name)s: %(message)s", level=log_level.value
    )
    logging.debug(f"helios database path: {db_path}")
    logging.debug(f"helios library path: {photo_dir}")
    ctx.obj = SimpleNamespace(db_path=db_path, photo_dir=photo_dir)


if __name__ == "__main__":
    app()
