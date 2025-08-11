# Nix function for building babashka scripts with proper dependency management
{
  lib,
  stdenv,
  babashka,
}:

let
  # Helper function to detect if a directory contains a bb.edn file
  hasBbEdn = dir: builtins.pathExists (dir + "/bb.edn");

  # Helper function to build a structured babashka project
  buildStructuredProject =
    {
      name,
      src,
      buildInputs ? [ ],
    }:
    {
      inherit name;
      type = "structured";
      build = ''
        # Copy the entire project structure
        mkdir -p $out/share/${name}
        cp -r ${src}/* $out/share/${name}/

        # Create a wrapper script that sets up classpath correctly
        cat > $out/bin/${name} << EOF
        #!${babashka}/bin/bb

        ;; Set working directory to project root
        (require '[babashka.classpath :as cp])

        ;; Add project src to classpath if it exists
        (when (.exists (java.io.File. "$out/share/${name}/src"))
          (cp/add-classpath "$out/share/${name}/src"))

        ;; Load and execute the main script
        (load-file "$out/share/${name}/${name}.bb")
        EOF
        chmod +x $out/bin/${name}
      '';
    };

  # Helper function to build a simple babashka script
  buildSimpleScript =
    { name, src }:
    {
      inherit name;
      type = "simple";
      build = ''
        # Copy the script directly to bin
        cp ${src} $out/bin/${name}
        chmod +x $out/bin/${name}
      '';
    };

in

# Main function to build babashka scripts
{
  pname,
  version,
  src,
  buildInputs ? [ ],
  meta ? { },
}:

stdenv.mkDerivation {
  inherit pname version meta;

  src = src;

  buildInputs = [ babashka ] ++ buildInputs;

  installPhase = ''
    mkdir -p $out/bin

    # Process simple scripts
    if [ -d simple ]; then
      for script in simple/*.bb; do
        if [ -f "$script" ]; then
          script_name=$(basename "$script" .bb)
          cp "$script" "$out/bin/$script_name"
          chmod +x "$out/bin/$script_name"
        fi
      done
    fi

    # Process structured projects
    if [ -d projects ]; then
      for project_dir in projects/*/; do
        if [ -d "$project_dir" ]; then
          project_name=$(basename "$project_dir")
          
          # Copy the entire project structure
          mkdir -p "$out/share/$project_name"
          cp -r "$project_dir"* "$out/share/$project_name/"
          
          # Find the main script (either project_name.bb or main entrypoint)
          main_script=""
          if [ -f "$out/share/$project_name/$project_name.bb" ]; then
            main_script="$project_name.bb"
          elif [ -f "$out/share/$project_name/main.bb" ]; then
            main_script="main.bb"
          else
            # Look for any .bb file in the root
            for bb_file in "$out/share/$project_name"/*.bb; do
              if [ -f "$bb_file" ]; then
                main_script=$(basename "$bb_file")
                break
              fi
            done
          fi
          
          # Create wrapper script if we found a main script
          if [ -n "$main_script" ]; then
            cat > "$out/bin/$project_name" << EOF
    #!${babashka}/bin/bb

    ;; Build-time version information
    (def *build-version* "${version}")

    ;; Set up classpath for structured project
    (require '[babashka.classpath :as cp])

    ;; Add shared/common to classpath if it exists
    (when (.exists (java.io.File. "$out/share/common/src"))
      (cp/add-classpath "$out/share/common/src"))

    ;; Add project src to classpath if it exists
    (when (.exists (java.io.File. "$out/share/$project_name/src"))
      (cp/add-classpath "$out/share/$project_name/src"))

    ;; Preserve command-line arguments and load the main script
    (binding [*command-line-args* *command-line-args*]
      (load-file "$out/share/$project_name/$main_script"))
    EOF
            chmod +x "$out/bin/$project_name"
          fi
        fi
      done
    fi

    # Set up shared utilities if they exist
    if [ -d shared ]; then
      mkdir -p "$out/share/common"
      cp -r shared/* "$out/share/common/"
    fi

    # Install completions if they exist
    if [ -d completions ]; then
      mkdir -p $out/share/zsh/site-functions
      find ./completions \( -type f -o -type l \) \
          -exec cp -pL {} $out/share/zsh/site-functions \;
      
      # Update paths in completion files
      sed -i -e "s|source dots_common\.bash|source $out/share/zsh/site-functions/dots_common\.bash|" $out/share/zsh/site-functions/* || true
    fi
  '';
}
