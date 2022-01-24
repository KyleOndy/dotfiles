self: super: {
  st = super.st.override {
    patches = [
      # set font to `hack`
      ./st-font_hack-20191111-75f92eb.diff
      # set colorscheme to `gruvbox`
      ./st-gruvbox-20220118-ded1e4c.diff
    ];
  };
}
