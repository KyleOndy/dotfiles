# clipboard access

The macOS pasteboard is reachable, so the human can paste images into the
prompt and `pbcopy`/`pbpaste` work. The clipboard can hold anything the
human copied, passwords and tokens included. Read it with `pbpaste` only
when asked to, and never write what it held into a file, a commit or a
command line. Writing to it with `pbcopy` is fine when the human asks for
something to paste.
