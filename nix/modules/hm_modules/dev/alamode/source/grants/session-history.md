# session transcript access

`~/.pi/agent/sessions` holds every past session's transcript, every
project's, the human's prompts included. With this grant the directory is
readable and writable, so the resume picker (`alt+r`) and cross-project
resume work inside this session. Without it they need the human, outside
the sandbox.

The default deny is the task-logs posture applied to transcripts: reading
them is a job for the human. The current project's own transcript
directory stays readable and writable either way (the engine names it after the
cwd), so this session's own recording and same-project resume keep
working; if the engine ever changes that encoding, resume fails loudly rather
than leaking. Other projects' directories are write-denied too, so a
session cannot plant entries in a transcript the human later resumes.
In strict mode the directory names stay listable, which shows which paths
have had a session, and nothing more.
