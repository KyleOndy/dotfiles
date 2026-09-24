# Host ports forge forwards out of its VMs, shared by the script, the lima
# configs and the guest image so none of them can drift from the others.
{
  # One per kind API server. The unnamed instance takes the first window and
  # instance n the window n spans above it (api_port_for in forge.sh).
  apiPortBase = 6440;
  apiPortSpan = 16;
  # The forge-cache VM's registry mirrors, one port each in MIRRORS order
  # (forge.sh), docker.io first because guest.nix points dockerd at it. Below
  # the API windows, and clear of 5000, which macOS's AirPlay receiver holds.
  cachePortBase = 6420;
  cachePortSpan = 16;
}
