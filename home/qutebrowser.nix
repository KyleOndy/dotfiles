{ ... }:

{
  programs = {
    qutebrowser = {
      enable = true;
      searchEngines = {
        DEFAULT = "https://duckduckgo.com/?q={}";
      };
    };
  };
}
