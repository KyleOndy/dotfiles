{
  lib,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.nutExporter;
in
{
  options.systemFoundry.monitoringStack.nutExporter = {
    enable = mkEnableOption "nut_exporter for UPS metrics from the local upsd on 127.0.0.1:9199";
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.prometheus.exporters.nut = {
      enable = true;
      listenAddress = "127.0.0.1";
      # upsd answers LIST VAR without a login, so there is no nutUser and no
      # password to keep anywhere.
      #
      # Variables not listed here are not exported, and the exporter's default
      # list lacks battery.runtime and output.voltage.
      #
      # ups.power is left out: this Tripp Lite reports 0.0 at any load, so the
      # UPS dashboard estimates watts from ups.load instead.
      nutVariables = [
        "battery.charge"
        "battery.runtime"
        "battery.voltage"
        "battery.voltage.nominal"
        "input.frequency"
        "input.voltage"
        "input.voltage.nominal"
        "output.frequency.nominal"
        "output.voltage"
        "output.voltage.nominal"
        "ups.beeper.status"
        "ups.delay.shutdown"
        "ups.load"
        "ups.power.nominal"
        "ups.status"
      ];
    };
  };
}
