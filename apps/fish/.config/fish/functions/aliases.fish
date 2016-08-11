# List only directories
alias lsd='ls -l | grep "^d"'

alias tree 'tree --dirsfirst -ChFQ'
function tree1; tree -L 1 $argv; end
function tree2; tree -L 2 $argv; end
function tree3; tree -L 3 $argv; end
function tree4; tree -L 4 $argv; end
function tree5; tree -L 5 $argv; end
function tree6; tree -L 6 $argv; end

alias treea "tree -a -I '.git|.stack-work' --dirsfirst -ChFQ"
function treea1; tree -L 1 $argv; end
function treea2; tree -L 2 $argv; end
function treea3; tree -L 3 $argv; end
function treea4; tree -L 4 $argv; end
function treea5; tree -L 5 $argv; end
function treea6; tree -L 6 $argv; end


function bigdirs; du -h --max-depth=1 $argv | sort -h; end


# Stack
alias ghc 'stack exec -- ghc'
alias ghci 'stack exec -- ghci'

# Old Habits
alias :q exit

alias gpg gpg2

# git
alias gst 'git status'
