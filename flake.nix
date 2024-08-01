{
  description = "Description for the project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
    nixos-anywhere.url = "github:numtide/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";
    disko.follows = "nixos-anywhere/disko";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.devenv.flakeModule
      ];
      systems = inputs.nixpkgs.lib.systems.flakeExposed;
      perSystem = {
        config,
        self',
        inputs',
        pkgs,
        system,
        ...
      }: {
        # Per-system attributes can be defined here. The self' and inputs'
        # module parameters provide easy access to attributes of the same
        # system.
        # Equivalent to  inputs'.nixpkgs.legacyPackages.hello;
        packages.nixosImg = pkgs.fetchurl {
          url = "https://hydra.nixos.org/build/237110262/download/1/nixos-minimal-23.11pre531102.fdd898f8f79e-aarch64-linux.iso";
          sha256 = "sha256-PF6EfDXHJDQHHHN+fXUKBcRIRszvpQrrWmIyltFHn5c=";
        };
        packages.utm = pkgs.utm;
        packages.nixosCmd = pkgs.writeShellApplication {
          name = "nixosCmd";
          runtimeInputs = [self'.packages.utm];
          text = ''
            TT=
            while [ -z "$TT" ]; do
              TT=$(utmctl attach "$VM_NAME" | sed -n -e 's/PTTY: //p')
              echo -n "."
              sleep 1
            done
            echo "TTY IS: $TT"
            DAT=/tmp/ttyDump.dat.''$''$
            trap 'rm "$DAT"' EXIT

            exec 3<"$TT"                         #REDIRECT SERIAL OUTPUT TO FD 3
            cat <&3 > "$DAT" &          #REDIRECT SERIAL OUTPUT TO FILE
            PID=$!                                #SAVE PID TO KILL CAT
            echo -e "$@" > "$TT";
            sleep 0.3s                          #WAIT FOR RESPONSE
            kill $PID                             #KILL CAT PROCESS
            wait $PID 2>/dev/null || true                 #SUPRESS "Terminated" output
            exec 3<&-
            cat $DAT
          '';
        };
        packages.nixosIP = pkgs.writeShellApplication {
          name = "nixosIP";
          runtimeInputs = [self'.packages.nixosCmd pkgs.gnused];
          text = ''
            UTM_DATA_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents";
            MAC=$(sed -ne 's/.*\(..:..:..:..:..:..\).*/\1/p' "$UTM_DATA_DIR/$VM_NAME.utm/config.plist")
            # shellcheck disable=SC2001
            MAC1=$(sed -e 's/0\([[:digit:]]\)/\1/g' <<< "$MAC")
            IP=
            while [ -z "$IP" ]; do
              IP=$(arp -a | sed -ne "s/.*(\([0-9.]*\)) at $MAC1.*/\1/p")
              sleep 1
            done
            echo "$IP"
          '';
        };
        packages.nixosSetRootPW = pkgs.writeShellApplication {
          name = "nixosSetRootPW";
          runtimeInputs = [self'.packages.nixosCmd];
          text = ''NIXOS_PW=$1; nixosCmd "echo -e '$NIXOS_PW\n$NIXOS_PW' | sudo passwd" '';
        };
        packages.sshNixos = pkgs.writeShellApplication {
          name = "sshNixos";
          runtimeInputs = [self'.packages.nixosIP pkgs.openssh self'.packages.utm];
          text = ''
            utmctl start "$VM_NAME" || true # be sure it is started, or start it
            VM_IP=$(nixosIP)
            # shellcheck disable=SC2029
            ssh "root@$VM_IP" "$@"
          '';
        };
        packages.killUTM = pkgs.writeShellApplication {
          name = "killUTM";
          runtimeInputs = [
            self'.packages.utm
            pkgs.coreutils
            pkgs.gnused
            pkgs.ps
          ];
          text = ''
            # shellcheck disable=SC2009
            if ps aux | grep '/[U]TM'; then
              UTM_PID=$(ps ax -o pid,command | grep '/[U]TM'| sed -ne 's/^[ ]*\([[:digit:]]*\) .*/\1/p')
              read -r -e -p "Running at $UTM_PID. Kill? (y/N)" -i "n" answer
              case "$answer" in
                y | Y | yes ) kill "$UTM_PID" ;;
                *) echo "don't stop UTM. abort."; exit ;;
              esac
            fi
          '';
        };
        packages.nixosCreate = pkgs.writeShellApplication {
          name = "nixosCreate";
          runtimeInputs = [
            pkgs.util-linux.bin
            pkgs.coreutils
            pkgs.gnused
            pkgs.openssh
            pkgs.ps
            self'.packages.utm
            self'.packages.nixosCmd
            self'.packages.nixosIP
            self'.packages.killUTM
            inputs'.nixos-anywhere.packages.default
          ];
          text = ''
            set -x
            FLAKE_CONFIG=''${1:-".#utm"}
            shift 1
            echo "## Check that the provided nixosConfiguration $FLAKE_CONFIG exists"
            nix eval "''${FLAKE_CONFIG/'#'/'#'nixosConfigurations.}.config.system.stateVersion"

            #MAC_ADDR=$(tr -dc A-F0-9 < /dev/urandom | head -c 10 | sed -r 's/(..)/\1:/g;s/:$//;s/^/02:/')
            MAC_ADDR=$(md5sum <<< "$VM_NAME" | head -c 10 | sed -r 's/(..)/\1:/g;s/:$//;s/^/02:/')


            if utmctl list | grep "$VM_NAME" ; then
              read -r -e -p "The VM [$VM_NAME] exists: should the VM be deleted (y/N)" -i "n" answer
              case "$answer" in
                y | Y | yes ) utmctl stop "$VM_NAME"; utmctl delete "$VM_NAME" ;;
                *) echo "keep existing VM. abort."; exit ;;
              esac
            fi

            echo "create the VM [$VM_NAME] from $FLAKE_CONFIG with applescript"
            osascript ${./setupVM.osa} "$VM_NAME" "$MAC_ADDR" ${self'.packages.nixosImg}

            echo "configure the VM with plutil"
            UTM_DATA_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents";
            FOLDER="$UTM_DATA_DIR/$VM_NAME.utm"
            CFG="$FOLDER"/config.plist
            plutil -insert "Display.0" -json '{ "HeightPixels": 1200, "PixelsPerInch": 226, "WidthPixels": 1920 }' "$CFG"
            plutil -replace "Virtualization.Rosetta" -bool true "$CFG"
            plutil -replace "Virtualization.Keyboard" -bool true "$CFG"
            plutil -replace "Virtualization.Trackpad" -bool true "$CFG"
            plutil -replace "Virtualization.Pointer" -bool true "$CFG"
            plutil -replace "Virtualization.Keybaord" -bool true "$CFG"
            plutil -replace "Virtualization.ClipboardSharing" -bool true "$CFG"
            plutil -replace "Virtualization.Audio" -bool true "$CFG"
            plutil -replace "Virtualization.Balloon" -bool true "$CFG"

            echo -e "\n\n## refresh UTMs view of the configuration requires restarting UTM"
            killUTM

            utmctl start "$VM_NAME"
            while ! nixosCmd ls | grep nixos ; do
              echo "VM $VM_NAME not yet running"
              sleep 2;
            done
            nixosCmd uname
            echo "VM $VM_NAME is running"

            echo "## configure ad-hoc authorized key for nixos-anywhere"
            INSTALL_KEY_FILE=$(mktemp -u)
            ssh-keygen -t ed25519 -N "" -f "$INSTALL_KEY_FILE"
            INSTALL_KEY_PUB=$(cat "$INSTALL_KEY_FILE.pub")
            nixosCmd "sudo mkdir -p /root/.ssh; echo '$INSTALL_KEY_PUB' | sudo tee -a /root/.ssh/authorized_keys"
            sleep 0.5;

            echo "## start the actuall installation"
            nixos-anywhere --flake "''${FLAKE_CONFIG}" "root@$(nixosIP)" --build-on-remote -i "$INSTALL_KEY_FILE" "$@"
            rm "$INSTALL_KEY_FILE" "$INSTALL_KEY_FILE".pub

            utmctl stop "$VM_NAME"
            osascript ${./removeIso.osa} "$VM_NAME"
            utmctl start "$VM_NAME"

            while ! ssh-keyscan "$(nixosIP)"; do sleep 2; done
            ssh-keygen -R "$(nixosIP)"
          '';
        };
        packages.nixosDeploy = pkgs.writeShellApplication {
          name = "nixosDeploy";
          runtimeInputs = [
            self'.packages.nixosIP
            #self'.packages.sshNixos
            pkgs.nixos-rebuild
          ];
          text = ''
            set -x
            FLAKE_CONFIG=$1
            shift
            THE_TARGET="root@$(nixosIP)"
            echo "Deploying $FLAKE_CONFIG to $THE_TARGET"
            export NIX_SSHOPTS="-o ControlPath=/tmp/ssh-utm-vm-%n"
            nixos-rebuild \
              --fast --target-host "$THE_TARGET" --build-host "$THE_TARGET" \
              switch --flake "$FLAKE_CONFIG" "$@"

            # experiment with copying flake manually
            #            FLAKE="''${FLAKE_CONFIG/'#'*}"
            #            REF=$(nix flake metadata "$FLAKE" --json | jq .path -r)
            #            nix copy "$REF" --to "ssh://$THE_TARGET"
            #
            #            CFG="''${FLAKE_CONFIG/*'#'}"
            #            sshNixos "nixos-rebuild switch --flake $REF#$CFG"
          '';
        };
        devenv.shells.default = {lib, ...}: {
          env.VM_NAME = "MyNixOS2";
          containers = lib.mkForce {};
          enterShell = ''
            export UTM_DATA_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents";
          '';
          packages = builtins.attrValues {
            inherit (self'.packages) nixosCreate sshNixos utm;
            inherit (pkgs) coreutils nixos-rebuild;
            inherit (inputs'.nixos-anywhere.packages) nixos-anywhere;
          };
        };
      };
      flake = {
        nixosConfigurations.utm = import ./example/default.nix inputs;
        templates.default = {
          path = ./example;
          description = "A basic UTM VM configuration";
        };
      };
    };
}
