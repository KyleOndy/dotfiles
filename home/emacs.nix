{ pkgs, ... }:

# https://gitlab.com/rycee/configurations/blob/d6dcf6480e29588fd473bd5906cd226b49944019/user/emacs.nix

let

  nurNoPkgs = import (
    builtins.fetchTarball
      "https://github.com/nix-community/NUR/archive/master.tar.gz"
  ) {};

in
{
  imports = [ nurNoPkgs.repos.rycee.hmModules.emacs-init ];

  services.emacs = { enable = true; };
  programs.emacs = {
    enable = true;
    package = pkgs.emacs;
    init = {
      enable = true;
      recommendedGcSettings = true;

      prelude = ''
        ;; lets start with some sane defaults

        ;;; Disable menu-bar, tool-bar, and scroll-bar.
        (if (fboundp 'menu-bar-mode)
            (menu-bar-mode -1))
        (if (fboundp 'tool-bar-mode)
            (tool-bar-mode -1))
        (if (fboundp 'scroll-bar-mode)
            (scroll-bar-mode -1))

        ;;; Useful Defaults
        (setq-default cursor-type 'bar)           ; Line-style cursor similar to other text editors
        (setq inhibit-startup-screen t)           ; Disable startup screen
        (setq initial-scratch-message "")         ; Make *scratch* buffer blank
        (setq-default frame-title-format '("%b")) ; Make window title the buffer name
        (setq ring-bell-function 'ignore)         ; Disable bell sound
        (setq-default show-trailing-whitespace t) ; Trailing white space are banned
        (fset 'yes-or-no-p 'y-or-n-p)             ; y-or-n-p makes answering questions faster
        (show-paren-mode 1)                       ; Show closing parens by default
        (setq linum-format "%4d ")                ; Prettify line number format
        (add-hook 'prog-mode-hook                 ; Show line numbers in programming modes
                  (if (fboundp 'display-line-numbers-mode)
                      #'display-line-numbers-mode
                    #'linum-mode))

        ;;; Avoid littering the user's filesystem with backups
        (setq
           backup-by-copying t      ; don't clobber symlinks
           backup-directory-alist
            '((".*" . "~/.emacs.d/saves/"))    ; don't litter my fs tree
           delete-old-versions t
           kept-new-versions 6
           kept-old-versions 2
           version-control t)       ; use versioned backups

        ;;; Lockfiles unfortunately cause more pain than benefit
        (setq create-lockfiles nil)
      '';
      usePackage = {

        # Lets counsel do prioritization. A fork of smex.
        amx = {
          enable = true;
          command = [ "amx-initialize" ];
        };

        # integration with a Clojure REPL
        # https://github.com/clojure-emacs/cider
        cider = { enable = true; };

        # key bindings and code colorization for Clojure
        # https://github.com/clojure-emacs/clojure-mode
        clojure-mode = { enable = true; };

        # extra syntax highlighting for clojure
        clojure-mode-extra-font-locking = { enable = true; };

        company = {
          enable = true;
          diminish = [ "company-mode" ];
          hook = [ "(after-init . global-company-mode)" ];
          extraConfig = ''
            :bind (:map company-mode-map
                        ([remap completion-at-point] . company-complete-common)
                        ([remap complete-symbol] . company-complete-common))
          '';
          config = ''
            (setq company-idle-delay 0.3
                  company-show-numbers t)
          '';
        };

        company-cabal = {
          enable = true;
          after = [ "company" ];
          command = [ "company-cabal" ];
          config = ''
            (add-to-list 'company-backends 'company-cabal)
          '';
        };

        company-quickhelp = {
          enable = true;
          after = [ "company" ];
          command = [ "company-quickhelp-mode" ];
          config = ''
            (company-quickhelp-mode 1)
          '';
        };

        counsel = {
          enable = true;
          diminish = [ "counsel-mode" ];
        };

        direnv = {
          enable = true;
          command = [ "direnv-mode" "direnv-update-environment" ];
        };

        dockerfile-mode = {
          enable = true;
          mode = [ ''"Dockerfile\\'"'' ];
        };

        evil = {
          enable = true;
          init = ''
            (setq evil-want-C-u-scroll t)
            (setq evil-vsplit-window-right t)
            (setq evil-split-window-below t)
            (setq evil-search-module 'evil-search)
          '';
          config = ''
            (require 'evil)

            ;;;; I wept with joy about this in:
            ;;;; http://www.mycpu.org/emacs-24-magit-magic/
            (define-key evil-ex-map "m" 'magit-blame)

            (defvar my-leader-map (make-sparse-keymap)
              "Keymap for \"leader key\" shortcuts.")

            ;; binding "SPC" to the keymap
            (define-key evil-normal-state-map (kbd "SPC") my-leader-map)

            ;; (o) binding for file access
            (define-key my-leader-map "oo" 'counsel-git)
            (define-key my-leader-map "of" 'counsel-fzf)
            (define-key my-leader-map "ob" 'counsel-buffer-or-recentf)

            ;; (g) binds for magit
            (define-key my-leader-map "g" 'magit-status)

            ;; (m) moving between windows
            (define-key my-leader-map "mh" 'evil-window-left)
            (define-key my-leader-map "mj" 'evil-window-down)
            (define-key my-leader-map "mk" 'evil-window-up)
            (define-key my-leader-map "ml" 'evil-window-right)

            (evil-mode 1)
          '';
        };

        # todo: try and make this work
        # evil bindings everywhere
        #evil-collection = { enable = true; };

        evil-surround = {
          enable = true;
        };

        flycheck = {
          enable = true;
          diminish = [ "flycheck-mode" ];
          command = [ "global-flycheck-mode" ];
          defer = 1;
          config = ''
            ;; Only check buffer when mode is enabled or buffer is saved.
            (setq flycheck-check-syntax-automatically '(mode-enabled save))
            (setq flycheck-highlighting-mode 'lines)

            ;; Enable flycheck in all eligible buffers.
            (global-flycheck-mode)
          '';
        };

        flycheck-haskell = {
          enable = true;
          hook = [ "(flycheck-mode . flycheck-haskell-setup)" ];
        };

        flyspell = {
          enable = true;
          diminish = [ "flyspell-mode" ];
          command = [ "flyspell-mode" "flyspell-prog-mode" ];
          hook = [
            # Spell check in text and programming mode.
            "(text-mode . flyspell-mode)"
            "(prog-mode . flyspell-prog-mode)"
          ];
          config = ''
            ;; In flyspell I typically do not want meta-tab expansion
            ;; since it often conflicts with the major mode. Also,
            ;; make it a bit less verbose.
            (setq flyspell-issue-message-flag nil
                  flyspell-issue-welcome-flag nil
                  flyspell-use-meta-tab nil)
          '';
        };

        groovy-mode = { enable = true; };

        gruvbox-theme = {
          enable = true;
          config = "(load-theme 'gruvbox t)";
        };

        ispell = {
          enable = true;
          defer = 1;
        };

        ivy = {
          enable = true;
          demand = true;
          diminish = [ "ivy-mode" ];
          command = [ "ivy-mode" ];
          config = ''
            (setq ivy-use-virtual-buffers t
                  ivy-count-format "%d/%d "
                  ivy-virtual-abbreviate 'full)

            ;; configure regexp engine.
            (setq ivy-re-builders-alist
                ;; allow input not in order
                '((t . ivy--regex-ignore-order)))

            (ivy-mode 1)
          '';
        };

        js = {
          enable = true;
          mode = [
            ''("\\.js\\'" . js-mode)''
            ''("\\.json\\'" . js-mode)''
          ];
          config = ''
            (setq js-indent-level 2)
          '';
        };

        json-mode = { enable = true; };

        magit = {
          enable = true;
          bind = { "C-c g" = "magit-status"; };
          config = ''
            (setq magit-completing-read-function 'ivy-completing-read)
            (add-to-list 'git-commit-style-convention-checks
                         'overlong-summary-line)
          '';
        };

        markdown-mode = {
          enable = true;
          mode = [
            ''"\\.mdwn\\'"''
            ''"\\.markdown\\'"''
            ''"\\.md\\'"''
          ];
        };

        nix-mode = {
          enable = true;
          mode = [ ''"\\.nix\\'"'' ];
          hook = [ "(nix-mode . subword-mode)" ];
        };

        projectile = {
          enable = true;
          diminish = [ "projectile-mode" ];
          command = [ "projectile-mode" ];
          bindKeyMap = {
            "C-c p" = "projectile-command-map";
          };
          config = ''
            (setq projectile-enable-caching t
                  projectile-completion-system 'ivy)
            (projectile-mode 1)
          '';
        };

        powershell = { enable = true; };

        puppet-mode = {
          enable = true;
          mode = [ ''("\\.pp\\'" . python-mode)'' ];
        };

        python = {
          enable = true;
          mode = [ ''("\\.py\\'" . python-mode)'' ];
          hook = [ "ggtags-mode" ];
        };

        # Use ripgrep for fast text search in projects. I usually use
        # this through Projectile.
        ripgrep = {
          enable = true;
          command = [ "ripgrep-regexp" ];
        };

        # Remember where we where in a previously visited file. Built-in.
        saveplace = {
          enable = true;
          config = ''
            (setq-default save-place t)
            (setq save-place-file (locate-user-emacs-file "places"))
          '';
        };

        swiper = {
          enable = true;
          command = [ "swiper" "swiper-all" "swiper-isearch" ];
          bind = {
            "C-s" = "swiper-isearch";
          };
        };

        terraform-mode = { enable = true; };

        undo-tree = { enable = true; };

        which-key = {
          enable = true;
          command = [ "which-key-mode" ];
          diminish = [ "which-key-mode" ];
          defer = 2;
          config = ''
            ;; Set the time delay (in seconds) for the which-key popup to appear. A value of
            ;; zero might cause issues so a non-zero value is recommended.
            (setq which-key-idle-delay 0.25)

            (which-key-mode)
          '';
        };

        yaml-mode = {
          enable = true;
          mode = [ ''"\\.yaml\\'"'' ];
        };
      };
    };
  };
}
