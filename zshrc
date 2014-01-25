#-------------------------------------------------------------
# General zsh config.
#-------------------------------------------------------------


# Path to your oh-my-zsh configuration.
ZSH=$HOME/.oh-my-zsh

# Set name of the theme to load.
# Look in ~/.oh-my-zsh/themes/
# Optionally, if you set this to "random", it'll load a random theme each
# time that oh-my-zsh is loaded.
ZSH_THEME="daveverwer"

# No one likes bells
setopt nobeep

#-------------------------------------------------------------
# Startup Programs
#-------------------------------------------------------------

# Randmon Quote Cow
command fortune -a | fmt -80 -s | $(shuf -n 1 -e cowsay cowthink) -$(shuf -n 1 -e b d g p s t w y) -f $(shuf -n 1 -e $(cowsay -l | tail -n +2)) -n

#-------------------------------------------------------------
# Key bindings
#-------------------------------------------------------------


#VIM Bindings
bindkey -v


#-------------------------------------------------------------
# Aliases
#-------------------------------------------------------------


alias :q='exit'


# Uncomment following line if you want red dots to be displayed while waiting for completion
COMPLETION_WAITING_DOTS="true"

# Which plugins would you like to load? (plugins can be found in ~/.oh-my-zsh/plugins/*)
# Custom plugins may be added to ~/.oh-my-zsh/custom/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
plugins=(git archlinux history-substring-search python vi-mode ssh-agent)

#-------------------------------------------------------------
# Sourcing other files
#-------------------------------------------------------------


source $ZSH/oh-my-zsh.sh


#-------------------------------------------------------------
# Path and Env
#-------------------------------------------------------------

export EDITOR=vim
export VISUAL=vim

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:/usr/bin/core_perl
export TERM=xterm-256color
export PATH=$PATH:/opt/android-sdk/platform-tools
