self: super: {
  st = super.st.override {
    patches = [
      # set font to `hack`
      ./st-font_hack-20191111-75f92eb.diff
      # set colorscheme to `gruvbox`
      ./st-gruvbox-20191111-75f92eb.diff
    ] ++ builtins.map super.fetchurl [
      {
        url = "https://st.suckless.org/patches/boxdraw/st-boxdraw_v2-0.8.2.diff";
        sha256 =
          "c1b7ab7672815b73e8328ecc55300c12fddce9ecae4ab04ff4377bd9132089f6";
      }
    ];
  };
}
