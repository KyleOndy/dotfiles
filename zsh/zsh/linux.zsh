if [[ "$OSTYPE" == linux* ]]; then
    # command not found; install pkgfile
    [[ -e /usr/share/doc/pkgfile/command-not-found.zsh ]] &&\
        source /usr/share/doc/pkgfile/command-not-found.zsh

    if [[ "$TERM" == xterm ]]; then
        export TERM=xterm-256color
    fi
fi
