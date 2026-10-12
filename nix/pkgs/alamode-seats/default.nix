{
  writers,
  seatsFile ? "",
  trustedProviders ? [ ],
  secretsSource ? "",
  relayModule ? "",
  privateProviderHosts ? [ ],
}:
writers.writePython3Bin "alamode-seats"
  {
    flakeIgnore = [
      "E501"
      "W503"
    ];
  }
  (
    builtins.replaceStrings
      [
        "@seatsFile@"
        "@trustedProviders@"
        "@secretsSource@"
        "@relayModule@"
        "@privateProviderHosts@"
      ]
      [
        seatsFile
        (builtins.concatStringsSep "," trustedProviders)
        secretsSource
        relayModule
        (builtins.concatStringsSep "," privateProviderHosts)
      ]
      (builtins.readFile ./alamode-seats.py)
  )
