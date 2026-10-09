# AltTab's settings, pinned so both macs match. Keys, their order and the
# enum indexes follow AltTab v11.9.0's src/preferences/Preferences.swift and
# MacroPreferences.swift. AltTab reads its prefs once at launch, so a change
# here lands on its next start.
{ config, lib, ... }:
let
  domain = "com.lwouis.alt-tab-macos";

  # AltTab stores shortcut N's copy of these as `<key>N`, and shortcut 1's
  # without a suffix.
  shortcut = suffix: appsToShow: {
    "appsToShow${suffix}" = appsToShow;
    "spacesToShow${suffix}" = "0"; # all
    "screensToShow${suffix}" = "0"; # all
    "showMinimizedWindows${suffix}" = "0"; # show
    "showHiddenWindows${suffix}" = "0"; # show
    "showFullscreenWindows${suffix}" = "0"; # show
    "showWindowlessApps${suffix}" = "2"; # showAtTheEnd
    "windowOrder${suffix}" = "0"; # recentlyFocused
    "showAppsOrWindows${suffix}" = "1"; # allWindows
    "showTabsAsWindows${suffix}" = "0"; # singleWindow
  };

  hide = {
    none = "0";
    always = "1";
    whenNoOpenWindow = "2";
  };
  ignore = {
    none = "0";
    whenFullscreen = "2";
  };
  exception = bundleIdentifier: hide: ignore: { inherit bundleIdentifier hide ignore; };

  # Shortcuts are dicts holding an NSKeyedArchiver blob. AltTab deletes one
  # without the blob as corrupt, and lib.generators.toPlist has no <data>
  # type, so CustomUserPreferences cannot write them. A per-shortcut
  # appearance override exists only by being stored. Deleting both leaves
  # every shortcut and override on AltTab's default.
  resetKeys = [
    "holdShortcut"
    "holdShortcut2"
    "nextWindowShortcut"
    "nextWindowShortcut2"
    "focusWindowShortcut"
    "previousWindowShortcut"
    "cancelShortcut"
    "closeWindowShortcut"
    "minDeminWindowShortcut"
    "toggleFullscreenWindowShortcut"
    "quitAppShortcut"
    "hideShowAppShortcut"
    "searchShortcut"
    "appearanceStyleOverride"
    "appearanceStyleOverride2"
    "appearanceSizeOverride"
    "appearanceSizeOverride2"
    "appearanceThemeOverride"
    "appearanceThemeOverride2"
    "shortcutStyleOverride"
    "shortcutStyleOverride2"
    "previewFocusedWindowOverride"
    "previewFocusedWindowOverride2"
  ];
in
{
  # Every value is a string. AltTab parses booleans with Swift's Bool(String),
  # which rejects the "1" a plist <true/> reads back as, and it deletes any
  # key it cannot parse.
  #
  # Left out: settingsWindowShownOnFirstLaunch and
  # screenRecordingPermissionSkipped record app state, and the per-shortcut
  # shortcutStyleN copies are never read.
  system.defaults.CustomUserPreferences.${domain} = {
    shortcutCount = "2";
    nextWindowGesture = "0"; # disabled
    showSearchHint = "true";
    arrowKeysEnabled = "true";
    vimKeysEnabled = "false";
    mouseHoverEnabled = "false";
    cursorFollowFocus = "0"; # never
    hideColoredCircles = "false";
    windowDisplayDelay = "100"; # ms
    appearanceStyle = "0"; # thumbnails
    appearanceSize = "0"; # small
    appearanceTheme = "2"; # system
    showOnScreen = "0"; # active
    titleTruncation = "2"; # end
    showTitles = "0"; # windowTitle
    fadeOutAnimation = "false";
    previewFadeInAnimation = "true";
    startAtLogin = "true";
    menubarIcon = "0"; # outlined
    menubarIconShown = "true";
    language = "0"; # systemDefault
    exceptions = builtins.toJSON [
      (exception "com.apple.finder" hide.whenNoOpenWindow ignore.none)
      (exception "com.apple.ScreenSharing" hide.none ignore.whenFullscreen)
      (exception "com.microsoft.rdc.macos" hide.none ignore.whenFullscreen)
      (exception "com.teamviewer.TeamViewer" hide.none ignore.whenFullscreen)
      (exception "org.virtualbox.app.VirtualBoxVM" hide.none ignore.whenFullscreen)
      (exception "com.parallels." hide.none ignore.whenFullscreen)
      (exception "com.citrix.XenAppViewer" hide.none ignore.whenFullscreen)
      (exception "com.citrix.receiver.icaviewer.mac" hide.none ignore.whenFullscreen)
      (exception "com.nicesoftware.dcvviewer" hide.none ignore.whenFullscreen)
      (exception "com.vmware.fusion" hide.none ignore.whenFullscreen)
      (exception "com.utmapp.UTM" hide.none ignore.whenFullscreen)
      (exception "com.McAfee.McAfeeSafariHost" hide.always ignore.none)
    ];
    updatePolicy = "1"; # autoCheck
    crashPolicy = "1"; # ask
    hideThumbnails = "false";
    hideSpaceNumberLabels = "true";
    hideStatusIcons = "false";
    previewFocusedWindow = "false";
    captureWindowsInBackground = "true";
    trackpadHapticFeedbackEnabled = "true";
    shortcutStyle = "0"; # focusOnRelease
  }
  # Option+Tab: every window of every app.
  // shortcut "" "0"
  # Option plus the key above Tab: windows of the active app only.
  // shortcut "2" "1";

  system.activationScripts.postActivation.text =
    let
      user = lib.escapeShellArg config.system.primaryUser;
    in
    ''
      for key in ${lib.escapeShellArgs resetKeys}; do
        launchctl asuser "$(id -u -- ${user})" sudo --user=${user} -- \
          defaults delete ${domain} "$key" 2>/dev/null || true
      done
    '';
}
