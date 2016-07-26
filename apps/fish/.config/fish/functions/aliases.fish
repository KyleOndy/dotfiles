# List only directories
alias lsd='ls -l | grep "^d"'

# from http://news.ycombinator.com/item?id=4492682
function tree1; tree --dirsfirst -ChFLQ 1 $argv; end
function tree2; tree --dirsfirst -ChFLQ 2 $argv; end
function tree3; tree --dirsfirst -ChFLQ 3 $argv; end
function tree4; tree --dirsfirst -ChFLQ 4 $argv; end
function tree5; tree --dirsfirst -ChFLQ 5 $argv; end
function tree6; tree --dirsfirst -ChFLQ 6 $argv; end
# My extension on the above
function treea; tree -a -I '.git|.stack-work' --dirsfirst -ChFQ $argv; end
function treea1; tree -a -I '.git|.stack-work' --dirsfirst -ChFLQ 1 $argv; end
function treea2; tree -a -I '.git|.stack-work' --dirsfirst -ChFLQ 2 $argv; end
function treea3; tree -a -I '.git|.stack-work' --dirsfirst -ChFLQ 3 $argv; end
function treea4; tree -a -I '.git|.stack-work' --dirsfirst -ChFLQ 4 $argv; end
function treea5; tree -a -I '.git|.stack-work' --dirsfirst -ChFLQ 5 $argv; end
function treea6; tree -a -I '.git|.stack-work' --dirsfirst -ChFLQ 6 $argv; end

function bigdirs; du -h --max-depth=1 $argv | sort -h; end


# Stack
alias ghc 'stack exec -- ghc'
alias ghci 'stack exec -- ghci'

# Old Habits
alias :q exit

alias gpg gpg2

# git
alias gst 'git status'
