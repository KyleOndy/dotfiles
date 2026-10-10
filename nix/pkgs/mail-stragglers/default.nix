{
  writeShellApplication,
  notmuch,
  python3,
}:

writeShellApplication {
  name = "mail-stragglers";
  runtimeInputs = [
    notmuch
    python3
  ];
  runtimeEnv.MAIL_STRAGGLERS_PY = ./mail-stragglers.py;
  text = builtins.readFile ./mail-stragglers.sh;
}
