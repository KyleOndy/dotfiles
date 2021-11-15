{ lib, pkgs, config, ... }:
with lib;
let
  cfg = config.hmFoundry.terminal.email;
  old_dots = ../../home/_dots_not_yet_in_nix;
in
{
  options.hmFoundry.terminal.email = {
    enable = mkEnableOption "email send / recieve";
  };

  config = mkIf cfg.enable {
    programs.mbsync.enable = true;
    programs.msmtp.enable = true;
    programs.notmuch = {
      enable = true;
      hooks = { preNew = "mbsync --all"; };
    };
    accounts.email = {
      maildirBasePath = "mail";
      accounts.kyle_at_ondy_org = {
        address = "kyle@ondy.org";
        maildir.path = "ondy.org";
        gpg = {
          key = "3C799D26057B64E6D907B0ACDB0E3C33491F91C9";
          signByDefault = true;
        };
        imap = {
          host = "london.mxroute.com";
          tls = { enable = true; };
        };
        mbsync = {
          enable = true;
          create = "maildir";
        };
        msmtp.enable = true;
        notmuch.enable = true;
        primary = true;
        realName = "Kyle Ondy";
        passwordCommand = "pass show email/kyle@ondy.org";
        smtp = {
          host = "london.mxroute.com";
          tls.enable = true;
        };
        userName = "kyle@ondy.org";
      };
    };
    home.packages = with pkgs; [
      neomutt # MUA
      urlview # easily open urls within emails
    ];
    xdg = {
      configFile."neomutt/neomuttrc".text = ''
                        # I18n
                        set charset       = utf-8
                        set send_charset  = utf-8

                        # Paths ----------------------------------------------
                        set folder           = ~/mail               # where email is stored
                        #set alias_file       = ~/.mutt/alias         # where to store aliases
                        #set header_cache     = ~/.mutt/cache/headers # where to store headers
                        #set message_cachedir = ~/.mutt/cache/bodies  # where to store bodies
                        #set certificate_file = ~/.mutt/certificates  # where to store certs
                        set mailcap_path     = ~/.config/neomutt/mailcap.muttrc
                        #set tmpdir           = ~/.mutt/temp          # where to keep temp files

                        source ./mutt-colors-solarized-dark-256.muttrc
                        #source ./mailboxes
                        source ./bindings.muttrc
                        source ./macros.muttrc
                        source ./gpg.muttrc
                        #source ./hooks.muttrc
                        #source $alias_file

                        # Mailboxes -----------------------------------------
                        set realname      = 'Kyle Ondy'
                        set from          = 'kyle@ondy.org'
                        set spoolfile     = "+ondy.org/Inbox"
                        set mbox          = "+ondy.org/Inbox"
                        set trash         = "+ondy.org/Trash"
                        set postponed     = "+ondy.org/Drafts"
                        set record        = "+ondy.org/Sent"
                        set sendmail      = "msmtp"
                        set sendmail_wait = 0

                        macro index S "<save-message>+ondy.org/Spam<enter>"  "mark message as spam"
                        macro index,pager A "<save-message>=ondy.org/Archive<enter>"     " move thread to archive"
                        macro index ,d \
                          "<tag-prefix><save-message>+ondy.org/Trash<enter>" \
                        "delete all"

                        mailboxes +ondy.org/Inbox \
                                  +ondy.org/Archive \
                                  +ondy.org/Drafts \
                                  +ondy.org/Sent \
                                  +ondy.org/Trash \
                                  +ondy.org/Junk \
                                  +ondy.org/spam

                        #### CLEAN BELOW

                        # Basic Options --------------------------------------
                        set wait_key = no        # shut up, mutt
                        set mbox_type = Maildir  # mailbox type
                        set timeout = 3          # idle time before scanning
                        set mail_check = 0       # minimum time between scans
                        set delete               # don't ask, just do
                        set quit                 # don't ask, just do!!
                        set beep_new             # bell on new mails
                        set pipe_decode          # strip headers and eval mimes when piping
                        set thorough_search      # strip headers and eval mimes before searching
                        set editor= 'nvim'
                        unset record

                        # Sidebar Patch --------------------------------------
                        set sidebar_visible
                        set sidebar_format = "%B%?F? [%F]?%* %?N?%N/?%S"
                        set mail_check_stats
                        set sidebar_short_path
                        #color sidebar_new yellow default
                        #
                        ## Status Bar -----------------------------------------
                        set status_chars  = " *%A"
                        set status_format = "───[ Folder: %f ]───[%r%m messages%?n? (%n new)?%?d? (%d to delete)?%?t? (%t tagged)? ]───%>─%?p?( %p postponed )?───"
                        #
                        #
                        ## Header Options -------------------------------------
                        ignore *                                # ignore all headers
                        unignore from: to: cc: date: subject:   # show only these
                        unhdr_order *                           # some distros order things by default
                        hdr_order from: to: cc: date: subject:  # and in this order

                        ## Account Settings -----------------------------------
                        ## Default inbox
                        #
                        ## Index View Options ---------------------------------
                        set date_format="%y-%m-%d %R"
                        set index_format = "[%Z]  %D  %-20.20F  %s"
                        set sort = threads                         # like gmail
                        set sort_aux = reverse-last-date-received  # like gmail
                        set uncollapse_jump                        # don't collapse on an unread message
                        set reply_regexp = "^(([Rr][Ee]?(\[[0-9]+\])?: *)?(\[[^]]+\] *)?)*"
                        set confirmappend=no
                        #
                        #
                        ## Compose View ----------------------------------
                        set envelope_from
                        set sig_dashes
                        set edit_headers
                        set fast_reply
                        set askcc
                        set fcc_attach
                        unset mime_forward
                        set forward_format = "Fwd: %s"
                        set forward_decode
                        set attribution = "On %d, %n wrote:"
                        set reply_to
                        set reverse_name
                        set include
                        set forward_quote
                        #
                        ## Pager View Options ---------------------------------
                        set pager_index_lines = 10 # number of index lines to show
                        set pager_context = 3      # number of context lines to show
                        set pager_stop             # don't go to next message automatically
                        set menu_scroll            # scroll in menus
                        set tilde                  # show tildes like in vim
                        unset markers              # no ugly plus signs

                        set quote_regexp = "^( {0,4}[>|:#%]| {0,4}[a-z0-9]+[>|]+)+"
                        alternative_order text/plain text/enriched text/html


                # Color scheme
                #
                # make sure that you are using mutt linked against slang, not ncurses, or
                # suffer the consequences of weird color issues. use "mutt -v" to check this.

                # custom body highlights -----------------------------------------------
                # highlight my name and other personally relevant strings
                #color body          color136        color234        "(ethan|schoonover)"
                # custom index highlights ----------------------------------------------
                # messages which mention my name in the body
                #color index         color136        color234        "~b \"phil(_g|\!| gregory| gold)|pgregory\" !~N !~T !~F !~p !~P"
                #color index         J_cream         color230        "~b \"phil(_g|\!| gregory| gold)|pgregory\" ~N !~T !~F !~p !~P"
                #color index         color136        color37         "~b \"phil(_g|\!| gregory| gold)|pgregory\" ~T !~F !~p !~P"
                #color index         color136        J_magent        "~b \"phil(_g|\!| gregory| gold)|pgregory\" ~F !~p !~P"
                ## messages which are in reference to my mails
                #color index         J_magent        color234        "~x \"(mithrandir|aragorn)\\.aperiodic\\.net|thorin\\.hillmgt\\.com\" !~N !~T !~F !~p !~P"
                #color index         J_magent        color230        "~x \"(mithrandir|aragorn)\\.aperiodic\\.net|thorin\\.hillmgt\\.com\" ~N !~T !~F !~p !~P"
                #color index         J_magent        color37         "~x \"(mithrandir|aragorn)\\.aperiodic\\.net|thorin\\.hillmgt\\.com\" ~T !~F !~p !~P"
                #color index         J_magent        color160        "~x \"(mithrandir|aragorn)\\.aperiodic\\.net|thorin\\.hillmgt\\.com\" ~F !~p !~P"

                # for background in 16 color terminal, valid background colors include:
                # base03, bg, black, any of the non brights

                # basic colors ---------------------------------------------------------
                color normal        color241        color234
                color error         color160        color234
                color tilde         color235        color234
                color message       color37         color234
                color markers       color160        color254
                color attachment    color254        color234
                color search        color61         color234
                #color status        J_black         J_status
                color status        color241        color235
                color indicator     color234        color136
                color tree          color136        color234                                    # arrow in threads

                # basic monocolor screen
                mono  bold          bold
                mono  underline     underline
                mono  indicator     reverse
                mono  error         bold

                # index ----------------------------------------------------------------

                #color index         color160        color234        "~D(!~p|~p)"               # deleted
                #color index         color235        color234        ~F                         # flagged
                #color index         color166        color234        ~=                         # duplicate messages
                #color index         color240        color234        "~A!~N!~T!~p!~Q!~F!~D!~P"  # the rest
                #color index         J_base          color234        "~A~N!~T!~p!~Q!~F!~D"      # the rest, new
                color index         color160        color234        "~A"                        # all messages
                color index         color166        color234        "~E"                        # expired messages
                color index         color33         color234        "~N"                        # new messages
                color index         color33         color234        "~O"                        # old messages
                color index         color61         color234        "~Q"                        # messages that have been replied to
                color index         color240        color234        "~R"                        # read messages
                color index         color33         color234        "~U"                        # unread messages
                color index         color33         color234        "~U~$"                      # unread, unreferenced messages
                color index         color241        color234        "~v"                        # messages part of a collapsed thread
                color index         color241        color234        "~P"                        # messages from me
                color index         color37         color234        "~p!~F"                     # messages to me
                color index         color37         color234        "~N~p!~F"                   # new messages to me
                color index         color37         color234        "~U~p!~F"                   # unread messages to me
                color index         color240        color234        "~R~p!~F"                   # messages to me
                color index         color160        color234        "~F"                        # flagged messages
                color index         color160        color234        "~F~p"                      # flagged messages to me
                color index         color160        color234        "~N~F"                      # new flagged messages
                color index         color160        color234        "~N~F~p"                    # new flagged messages to me
                color index         color160        color234        "~U~F~p"                    # new flagged messages to me
                color index         color235        color160        "~D"                        # deleted messages
                color index         color245        color234        "~v~(!~N)"                  # collapsed thread with no unread
                color index         color136        color234        "~v~(~N)"                   # collapsed thread with some unread
                color index         color64         color234        "~N~v~(~N)"                 # collapsed thread with unread parent
                # statusbg used to indicated flagged when foreground color shows other status
                # for collapsed thread
                color index         color160        color235        "~v~(~F)!~N"                # collapsed thread with flagged, no unread
                color index         color136        color235        "~v~(~F~N)"                 # collapsed thread with some unread & flagged
                color index         color64         color235        "~N~v~(~F~N)"               # collapsed thread with unread parent & flagged
                color index         color64         color235        "~N~v~(~F)"                 # collapsed thread with unread parent, no unread inside, but some flagged
                color index         color37         color235        "~v~(~p)"                   # collapsed thread with unread parent, no unread inside, some to me directly
                color index         color136        color160        "~v~(~D)"                   # thread with deleted (doesn't differentiate between all or partial)
                #color index         color136        color234        "~(~N)"                    # messages in threads with some unread
                #color index         color64         color234        "~S"                       # superseded messages
                #color index         color160        color234        "~T"                       # tagged messages
                #color index         color166        color160        "~="                       # duplicated messages

                # message headers ------------------------------------------------------

                #color header        color240        color234        "^"
                color hdrdefault    color240        color234
                color header        color241        color234        "^(From)"
                color header        color33         color234        "^(Subject)"

                # body -----------------------------------------------------------------

                color quoted        color33         color234
                color quoted1       color37         color234
                color quoted2       color136        color234
                color quoted3       color160        color234
                color quoted4       color166        color234

                color signature     color240        color234
                color bold          color235        color234
                color underline     color235        color234
                color normal        color244        color234
                #
                color body          color245        color234        "[;:][-o][)/(|]"    # emoticons
                color body          color245        color234        "[;:][)(|]"         # emoticons
                color body          color245        color234        "[*]?((N)?ACK|CU|LOL|SCNR|BRB|BTW|CWYL|\
                                                                     |FWIW|vbg|GD&R|HTH|HTHBE|IMHO|IMNSHO|\
                                                                     |IRL|RTFM|ROTFL|ROFL|YMMV)[*]?"
                color body          color245        color234        "[ ][*][^*]*[*][ ]?" # more emoticon?
                color body          color245        color234        "[ ]?[*][^*]*[*][ ]" # more emoticon?

                ## pgp

                color body          color160        color234        "(BAD signature)"
                color body          color37         color234        "(Good signature)"
                color body          color234        color234        "^gpg: Good signature .*"
                color body          color241        color234        "^gpg: "
                color body          color241        color160        "^gpg: BAD signature from.*"
                mono  body          bold                            "^gpg: Good signature"
                mono  body          bold                            "^gpg: BAD signature from.*"

                # yes, an insance URL regex
                color body          color160        color234        "([a-z][a-z0-9+-]*://(((([a-z0-9_.!~*'();:&=+$,-]|%[0-9a-f][0-9a-f])*@)?((([a-z0-9]([a-z0-9-]*[a-z0-9])?)\\.)*([a-z]([a-z0-9-]*[a-z0-9])?)\\.?|[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)(:[0-9]+)?)|([a-z0-9_.!~*'()$,;:@&=+-]|%[0-9a-f][0-9a-f])+)(/([a-z0-9_.!~*'():@&=+$,-]|%[0-9a-f][0-9a-f])*(;([a-z0-9_.!~*'():@&=+$,-]|%[0-9a-f][0-9a-f])*)*(/([a-z0-9_.!~*'():@&=+$,-]|%[0-9a-f][0-9a-f])*(;([a-z0-9_.!~*'():@&=+$,-]|%[0-9a-f][0-9a-f])*)*)*)?(\\?([a-z0-9_.!~*'();/?:@&=+$,-]|%[0-9a-f][0-9a-f])*)?(#([a-z0-9_.!~*'();/?:@&=+$,-]|%[0-9a-f][0-9a-f])*)?|(www|ftp)\\.(([a-z0-9]([a-z0-9-]*[a-z0-9])?)\\.)*([a-z]([a-z0-9-]*[a-z0-9])?)\\.?(:[0-9]+)?(/([-a-z0-9_.!~*'():@&=+$,]|%[0-9a-f][0-9a-f])*(;([-a-z0-9_.!~*'():@&=+$,]|%[0-9a-f][0-9a-f])*)*(/([-a-z0-9_.!~*'():@&=+$,]|%[0-9a-f][0-9a-f])*(;([-a-z0-9_.!~*'():@&=+$,]|%[0-9a-f][0-9a-f])*)*)*)?(\\?([-a-z0-9_.!~*'();/?:@&=+$,]|%[0-9a-f][0-9a-f])*)?(#([-a-z0-9_.!~*'();/?:@&=+$,]|%[0-9a-f][0-9a-f])*)?)[^].,:;!)? \t\r\n<>\"]"
                # and a heavy handed email regex
                #color body          J_magent        color234        "((@(([0-9a-z-]+\\.)*[0-9a-z-]+\\.?|#[0-9]+|\\[[0-9]?[0-9]?[0-9]\\.[0-9]?[0-9]?[0-9]\\.[0-9]?[0-9]?[0-9]\\.[0-9]?[0-9]?[0-9]\\]),)*@(([0-9a-z-]+\\.)*[0-9a-z-]+\\.?|#[0-9]+|\\[[0-9]?[0-9]?[0-9]\\.[0-9]?[0-9]?[0-9]\\.[0-9]?[0-9]?[0-9]\\.[0-9]?[0-9]?[0-9]\\]):)?[0-9a-z_.+%$-]+@(([0-9a-z-]+\\.)*[0-9a-z-]+\\.?|#[0-9]+|\\[[0-2]?[0-9]?[0-9]\\.[0-2]?[0-9]?[0-9]\\.[0-2]?[0-9]?[0-9]\\.[0-2]?[0-9]?[0-9]\\])"

                # Various smilies and the like
                #color body          color230        color234        "<[Gg]>"                            # <g>
                #color body          color230        color234        "<[Bb][Gg]>"                        # <bg>
                #color body          color136        color234        " [;:]-*[})>{(<|]"                  # :-) etc...
                # *bold*
                #color body          color33         color234        "(^|[[:space:][:punct:]])\\*[^*]+\\*([[:space:][:punct:]]|$)"
                #mono  body          bold                            "(^|[[:space:][:punct:]])\\*[^*]+\\*([[:space:][:punct:]]|$)"
                # _underline_
                #color body          color33         color234        "(^|[[:space:][:punct:]])_[^_]+_([[:space:][:punct:]]|$)"
                #mono  body          underline                       "(^|[[:space:][:punct:]])_[^_]+_([[:space:][:punct:]]|$)"
                # /italic/  (Sometimes gets directory names)
                #color body         color33         color234        "(^|[[:space:][:punct:]])/[^/]+/([[:space:][:punct:]]|$)"
                #mono body          underline                       "(^|[[:space:][:punct:]])/[^/]+/([[:space:][:punct:]]|$)"

                # Border lines.
                #color body          color33         color234        "( *[-+=#*~_]){6,}"

                #folder-hook .                  "color status        J_black         J_status        "
                #folder-hook gmail/inbox        "color status        J_black         color136        "
                #folder-hook gmail/important    "color status        J_black         color136        "


                # Bindings
        bind attach,index,pager \CD next-page
        bind attach,index,pager \CU previous-page

        bind index,pager <down>   sidebar-next
        bind index,pager <up>     sidebar-prev
        bind index,pager <right>  sidebar-open

        bind attach,index g        noop
        bind attach,index gg       first-entry
        bind attach,index G        last-entry

        bind index R        group-reply
        bind index <tab>    sync-mailbox
        bind index <space>  collapse-thread


        bind pager k  previous-line
        bind pager g  noop
        bind pager j  next-line
        bind pager gg top
        bind pager G  bottom

        bind pager R  group-reply

        #bind compose p postpone-message    # intefears with PGP
        bind index p recall-message

        # View attachments properly.
        bind attach <return> view-mailcap

        # macros

        # Saner copy/move dialogs
        macro index C "<copy-message>?<toggle-mailboxes>" "copy a message to a mailbox"
        macro index M "<save-message>?<toggle-mailboxes>" "move a message to a mailbox"


        # Macros ---------------------------------------------
        macro index,pager S '<sync-mailbox><shell-escape>mbsync -a<enter>'

        # GPG

        set crypt_use_gpgme=yes
        set pgp_sign_as = 0xDB0E3C33491F91C9
        set crypt_autosign                              # sign all outgoing messages
        set crypt_replyencrypt                          # encrypt replies to messages which are encrypted
        set crypt_replysignencrypted                    # encrypt and sign replies to encryped messages
        set pgp_good_sign="^gpg: Good signature from"


        # mailcap
        application/octet-stream ; echo %s "can be anything..."
        text/html                ; firefox %s
        application/pdf          ; /usr/bin/zathura %s
        image/*                  ; /usr/bin/feh %s
        audio/*                  ; /usr/bin/mpv %s
        video/*                  ; /usr/bin/mpv %s
        text/plain               ; cat %s                       ; copiousoutput
        text/x-diff              ; vim -R %s
        text/x-patch             ; vim -R %s
      '';
    };
  };
}
