#! /usr/bin/env nix-shell
#! nix-shell -i python3 -p python310 python310Packages.flask python310Packages.requests
# vi: ft=python

from flask import Flask, abort
import json
import logging
import requests
import re


app = Flask(__name__)
netboot_url = "http://localhost:3030"


logging.basicConfig(level=logging.INFO)


def get_ipixe(hostname):
    r = requests.get(f"{netboot_url}/dispatch/configuration/{hostname}")
    content = r.content
    # app.logger.debug(f"content: '{content}'")
    boot_string = parse_ipixe_response(content)
    return boot_string


def mac_to_hostname(mac_address):
    """
    This may eventually read from a config file or something else. Pretty
    much just map a mac addrress to a host name, where a hostname then maps to
    a machine configuration.
    """
    if mac_address in ["00:1e:06:45:28:5c", "00:1e:06:45:28:5d"]:
        return "w1"
    elif mac_address in ["00:1e:06:45:20:02", "00:1e:06:45:20:03"]:
        return "w2"
    elif mac_address in ["00:1e:06:45:2e:ec", "00:1e:06:45:2e:ed"]:
        return "w3"
    else:
        return None


def get_configuration_ipxe_script(hostname):
    """
    There is probably a way better way to do this. Request the ipxe script from
    nix-netboot-serve.
    """
    r = requests.get(f"{netboot_url}/dispatch/configuration/{hostname}")
    r.raise_for_status()

    script = r.content
    return script


def parse_ipxe_script(script):
    """
    The ipxe script is return as shown below. This parses out the infomation we
    need from the script. This is going to be really fragile and the most
    likely part of the process to break.

    ```
    #!ipxe
    echo Booting NixOS closure 9wjmnqnzvq9v77mgi179ply2hxdpjaj1-nixos-system-w1-22.05pre-git. Note: initrd may stay pre-0% for a minute or two.

    kernel bzImage rdinit=/nix/store/9wjmnqnzvq9v77mgi179ply2hxdpjaj1-nixos-system-w1-22.05pre-git/init loglevel=4
    initrd initrd
    boot
    ```
    """
    match = re.search(r"\/nix\/store\/.*\/", script.decode("utf-8"))
    if match is None:
        return None

    nix_path = match.group(0)
    closure_uuid = nix_path.split("/")[3]
    r = {
        "kernel": f"{netboot_url}/boot/{closure_uuid}/bzImage",
        "initrd": [f"{netboot_url}/boot/{closure_uuid}/initrd"],
        "cmdline": " ".join(
            [
                # the command line example was taken from nix-netboot-serve's readme
                f"rdinit={nix_path}init",
                "loglevel=4",
            ]
        ),
    }
    app.logger.info(f"The boot praramaters are '{r}'")
    return r


@app.route("/v1/boot/<mac>")
def boot(mac):
    # todo: move this into a config file
    app.logger.debug(f"got mac of '{mac}'")

    hostname = mac_to_hostname(mac)
    if hostname is None:
        app.logger.warn(f"no definition for '{mac}' found")
        abort(404)

    script = get_configuration_ipxe_script(hostname)
    boot_params = parse_ipxe_script(script)

    return json.dumps(boot_params)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port="3031")
