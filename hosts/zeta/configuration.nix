{ config, pkgs, ... }:

{
  imports = [ # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./../_includes/common.nix
    ./../_includes/docker.nix
    ./../_includes/kyle.nix
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.device = "/dev/sda"; # or "nodev" for efi only
  virtualisation.vmware.guest = { enable = true; };

  networking.hostName = "zeta";
  networking.networkmanager.enable = true;

  system.stateVersion = "19.09"; # Did you read the comment?

  security.pki.certificates = [
    ''
      BX-Root
      =======
      -----BEGIN CERTIFICATE-----
      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
      9xM6Mus/QZOxXIbYGrhzNCWS/+nCdc4p
      -----END CERTIFICATE-----
    ''
    ''
      BX-SubCA
      ========
      -----BEGIN CERTIFICATE-----
      MIIIOTCCBiGgAwIBAgIKYQMoOAABAAAACzANBgkqhkiG9w0BAQUFADBCMRMwEQYK
      CZImiZPyLGQBGRYDY29tMRowGAYKCZImiZPyLGQBGRYKYmxhY2tzdG9uZTEPMA0G
      A1UEAxMGcm9vdENBMB4XDTE1MDQyOTE1MzMyMFoXDTI1MDQyMzIwNDYxOVowQjET
      MBEGCgmSJomT8ixkARkWA2NvbTEaMBgGCgmSJomT8ixkARkWCkJsYWNrc3RvbmUx
      DzANBgNVBAMTBnN1YkNBMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB
      AKb0NbPmbbGjfUCrGGG1Spo2jBRLprqN69X77M2hxFNdMTlm09a1mTs40hk/cc2x
      i0U2XrhUHhh47egTI/RB7i5W+ScM/zW9xB4P4Py78aRp6mgDKB0DztZ5IHTVRTf7
      U5evaxERa7KlVmcmLG9OSWu/eLoK/+EJ/igucFeiClWlEnaC88SUALNKmNeUDJ7q
      b3C3ziJJiCQsZXHoSZyUYTxxP+NA3lg5iYIwL0fe5TG4kV2pZ4+/ef0Q2fZIXTaA
      p5jNF1N8lu9FU3Y2+MCWjyNXeP3cmIRR5oEGCKx1qb+A/tMrT550zGuiUzb9uahT
      ABRbH84JNmLmQU/faSfkXawT8FOdvJQFA1fahj80QQTIkni2QdLgxzYk64SKtXKW
      EU1iVNSejnusXR9wGIE9Ue+eXBmqgff6K5b+LczFfPUgep/UP7AYnbzLbtO2kpaH
      S8DqR8oZgz4OEXOgPYqdTYjLmXmSy0szaFlfNhrddjdRejO7/gQda2clmFoVWDk0
      I+DStCqnpbVYasyKNe7Py3aDFYXlRs+j6mHhDRODVEMsUPq/Qv1Hm9QbpdAeRSg6
      fPqO14M02SnHPU3VWV+vLdi1kW60pUkIkY9UMIRKcdFsULONgLDKFT3he7H1+mXv
      sioosDL7zkXoo8kY0i+ZskyZaFQ3nX24qQWn91hS62lbAgMBAAGjggMvMIIDKzAQ
      BgkrBgEEAYI3FQEEAwIBAzAjBgkrBgEEAYI3FQIEFgQUHgghvPY6SZDPAp5XIzdw
      110qIW0wHQYDVR0OBBYEFBT+6tpcNFaJsQpfHzcnknMA2xc6MBkGCSsGAQQBgjcU
      AgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8G
      A1UdIwQYMBaAFBZZPcUTVHYTiFkuAjN5Nk0kENhIMIIBJwYDVR0fBIIBHjCCARow
      ggEWoIIBEqCCAQ6GgadsZGFwOi8vL0NOPXJvb3RDQSxDTj1WQUJYQ0FST09UUDAx
      LENOPUNEUCxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxE
      Qz1VbmF2YWlsYWJsZUNvbmZpZ0ROP2NlcnRpZmljYXRlUmV2b2NhdGlvbkxpc3Q/
      YmFzZT9vYmplY3RDbGFzcz1jUkxEaXN0cmlidXRpb25Qb2ludIYvaHR0cDovL3Ri
      Zy1zdWJjYTEuYmxhY2tzdG9uZS5jb20vcGtpL3Jvb3RDQS5jcmyGMWZpbGU6Ly9c
      XHRiZy1zdWJjYTEuYmxhY2tzdG9uZS5jb21ccGtpXHJvb3RDQS5jcmwwggFMBggr
      BgEFBQcBAQSCAT4wggE6MIGZBggrBgEFBQcwAoaBjGxkYXA6Ly8vQ049cm9vdENB
      LENOPUFJQSxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxE
      Qz1VbmF2YWlsYWJsZUNvbmZpZ0ROP2NBQ2VydGlmaWNhdGU/YmFzZT9vYmplY3RD
      bGFzcz1jZXJ0aWZpY2F0aW9uQXV0aG9yaXR5MEwGCCsGAQUFBzAChkBodHRwOi8v
      dGJnLXN1YmNhMS5ibGFja3N0b25lLmNvbS9wa2kvVkFCWENBUk9PVFAwMV9yb290
      Q0EoMSkuY3J0ME4GCCsGAQUFBzAChkJmaWxlOi8vXFx0Ymctc3ViY2ExLmJsYWNr
      c3RvbmUuY29tXHBraVxWQUJYQ0FST09UUDAxX3Jvb3RDQSgxKS5jcnQwDQYJKoZI
      hvcNAQEFBQADggIBAB4fQi082/JjIdpCWt8ofS6YhK6XiY68i9EkBUWYhEPvMGlp
      DO+78Y39bgNFb7cABcGreyQt8jKd9075S9UzlIuBF6V3NqE//q+aTEWGIe9zIswc
      DgKYIadQt/EDHmS/D1ye/PvILNBDdtKxDnzPHhF5el6jfaSz9d88LxMe5iEe1y48
      vP6n9qH3FVj0XI3rWXBpLKy+aVnW5pUxDtZXZnk7vAPHOJ6tWuEPOTFwYq4Ze/+R
      dFexqiY5LLk8GaYGo3p1ljxXur2jCScQt2JhKbAMfxXFtLSXYEqXm7OBPUXT6Jv9
      qp5DiUHMFp0ywnP8sexaO3s5TyuYl6hfINZym2hLJR2VfrBjZSHrAAf/m0d6B5iv
      z8vOm540TNlkOW+0IGVsm8pzIM1qPkbrRFkHRTTzY8cfV13FzeNBnX4NMwCHIYSt
      g67RswRfk9529GNSJJho+dnxSiBCQk/GcQ1w/K7yJpRIwgaSNx+4mGYMIIbwGdZ4
      wSxarDRAWctLt+ib+1ZWFcXrm/BkPWKO0rlo67g7AEMehooaBbUfpv6WrZ4d3aQl
      47QNS6D0XRX9XOngSp7+qUiic/stfKBh27AWvcPyUiV8Z/ELep5zaKYQv8scG6Fg
      Shl12DSwhf6I2jFn657edUXlOsNcp+Igp6owAbTqy0EikfXWKqnCeN/s7hl8
      -----END CERTIFICATE-----
    ''
  ];
}

