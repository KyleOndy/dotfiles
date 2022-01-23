# TODO

## Bootstapping

- Be able to run `make netboot` and build a netboot image, and server it via [pixicore](https://github.com/danderson/netboot/tree/master/pixiecore)
- write instructions on how to intall nixos on hardware

- Look into [Graham Christensen](https://twitter.com/grhmc) pxe on demand stuff. Combine with erase your darlings

## Services

- Move tiger to DMZ. Lets me easily server content to internet, build host, apps, binary cache, etc.

  - IMPLICATION: will need backup ZFS server to PULL from this server since tiget can't reach out to it

  serve things under `apps.ondy.org`

- host under `apps.509ely.com`
  - setup wildcard `*.apps.509ely.com` to DDNS address of home
    - `sonarr.apps.509ely.com`
    - `radarr.apps.509ely.com`
    - `nzbget.apps.509ely.com`
    - `nzbhydra2.apps.509ely.com`
    - `jellyfin.apps.509ely.com`
    - `git.apps.509ely.com`
    - `concourse.apps.509ely.com`
    - `hydra.apps.509ely.com`
- setup TF to manage DNS for `ondy.org`
- setup vanity urls for `<foo>.ondy.org` as desired in TF
  - git.ondy.org
  - jellyfin.ondy.org
  - nixcache.ondy.org
  - ci.ondy.org
