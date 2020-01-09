{ pkgs, ... }:

# https://gitlab.com/rycee/configurations/blob/d6dcf6480e29588fd473bd5906cd226b49944019/user/emacs.nix

let

  nurNoPkgs = import (builtins.fetchTarball
    "https://github.com/nix-community/NUR/archive/master.tar.gz") { };

in {
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
        evil = {
          enable = true;
          config = ''
            (require 'evil)
            (evil-mode 1)
          '';
        };

        magit = {
          enable = true;
          #bind = { "C-c g" = "magit-status"; };
          #config = ''
          #  (setq magit-completing-read-function 'ivy-completing-read)
          #  (add-to-list 'git-commit-style-convention-checks
          #               'overlong-summary-line)
          #'';
        };

        # key bindings and code colorization for Clojure
        # https://github.com/clojure-emacs/clojure-mode
        clojure-mode = { enable = true; };

        # extra syntax highlighting for clojure
        clojure-mode-extra-font-locking = { enable = true; };

        # integration with a Clojure REPL
        # https://github.com/clojure-emacs/cider
        cider = { enable = true; };
        gruvbox-theme = {
          enable = true;
          config = "(load-theme 'gruvbox t)";
        };
        undo-tree = { enable = true; };
        yaml-mode = {
          enable = true;
          config = ''
            (require 'yaml-mode)
            (add-to-list 'auto-mode-alist '("\\.yml\\'" . yaml-mode))
                  '';
        };
        nix-mode = {
          enable = true;
          config = ''
            (require 'nix-mode)
            (add-to-list 'auto-mode-alist '("\\.nix\\'" . nix-mode))
          '';
        };
      };
    };
  };

}
