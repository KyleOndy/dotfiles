{
  writers,
  seatsFile ? "",
  trustedProviders ? [ ],
  secretsSource ? "",
}:
writers.writePython3Bin "pi-seats"
  {
    flakeIgnore = [
      "E501"
      "W503"
    ];
  }
  (
    builtins.replaceStrings
      [ "@seatsFile@" "@trustedProviders@" "@secretsSource@" ]
      [ seatsFile (builtins.concatStringsSep "," trustedProviders) secretsSource ]
      (builtins.readFile ./pi-seats.py)
  )
