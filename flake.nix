{
  description = "Description for the project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11-small";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
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
        packages.nixosInstallerImg = pkgs.fetchurl {
          # the image is only used for bootstrapping. It will be overwritten by nixos-anywhere
          # the final version is defined by the configuration you provide in `nixosCreate`
          # Build 280619599 of job nixos:release-24.11:nixos.iso_minimal.aarch64-linux
          url = "https://hydra.nixos.org/build/280619599/download/1/nixos-minimal-24.11.710050.62c435d93bf0-aarch64-linux.iso";
          sha256 = "sha256-BUYqZLwpeSda+wjRvDsYL/AP+KE653ymLuyKUlSGe7A=";
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
        packages.nixosSetRootPW = pkgs.writeShellApplication {
          name = "nixosSetRootPW";
          runtimeInputs = [self'.packages.nixosCmd];
          text = ''NIXOS_PW=$1; nixosCmd "echo -e '$NIXOS_PW\n$NIXOS_PW' | sudo passwd" '';
        };
        packages.sshNixos = pkgs.writeShellApplication {
          name = "sshNixos";
          runtimeInputs = [self'.packages.utmConfiguration pkgs.openssh self'.packages.utm];
          text = ''
            utmctl start "$VM_NAME" || true # be sure it is started, or start it
            VM_IP=$(utmConfiguration ip)
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
            pkgs.procps
          ];
          text = ''
            # shellcheck disable=SC2009
            if pgrep '[U]TM'; then
              echo "exists"
              UTM_PID=$(pgrep '[U]TM')
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
            self'.packages.killUTM
            self'.packages.utmConfiguration
            pkgs.nixos-anywhere
          ];
          text = ''
            set -x
            FLAKE_CONFIG=''${1:-".#utm"}
            shift 1

            # define UTM_CONFIG -- or fallback to provided default
            : "''${UTM_CONFIG:=${./utm.config.nix}}"

            echo "## Check that the provided nixosConfiguration $FLAKE_CONFIG exists"
            nix eval "''${FLAKE_CONFIG/'#'/'#'nixosConfigurations.}.config.system.stateVersion"

            # deterministically generate mac address from VM_NAME
            MAC_ADDR=$(md5sum <<< "$VM_NAME" | head -c 10 | sed -r 's/(..)/\1:/g;s/:$//;s/^/02:/')

            if utmctl list | grep "$VM_NAME" ; then
              read -r -e -p "The VM [$VM_NAME] exists: should the VM be deleted (y/N)" -i "n" answer
              case "$answer" in
                y | Y | yes ) utmctl stop "$VM_NAME"; utmctl delete "$VM_NAME" ;;
                *) echo "keep existing VM. abort."; exit ;;
              esac
            fi

            echo "create the VM [$VM_NAME] from $FLAKE_CONFIG with applescript"
            osascript ${./setupVM.osa} "$VM_NAME" "$MAC_ADDR" ${self'.packages.nixosInstallerImg}

            echo "configure the VM with plutil"
            utmConfiguration update "$UTM_CONFIG"
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
            NIXOS_IP=$(utmConfiguration ip)
            nixos-anywhere --flake "''${FLAKE_CONFIG}" "root@$NIXOS_IP" --build-on-remote -i "$INSTALL_KEY_FILE" "$@"
            rm "$INSTALL_KEY_FILE" "$INSTALL_KEY_FILE".pub

            utmctl stop "$VM_NAME"
            osascript ${./removeIso.osa} "$VM_NAME"
            utmctl start "$VM_NAME"

            while ! ssh-keyscan "$NIXOS_IP"; do sleep 2; done
            ssh-keygen -R "$NIXOS_IP"
          '';
        };
        packages.utmConfiguration = pkgs.writeShellApplication {
          name = "utmConfiguration";
          runtimeInputs = [pkgs.jq pkgs.coreutils pkgs.gnused];
          text = ''
            # INPUTS: VM_NAME
            UTM_DATA_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents";
            VM_FOLDER="$UTM_DATA_DIR/$VM_NAME.utm"
            PLIST_FILE="$VM_FOLDER"/config.plist

            case "''${1:-usage}" in
              show)
                plutil -convert json -o - "$PLIST_FILE" | jq .
                ;;

              mac)
                $0 show | jq '.Network[0].MacAddress' -r
                ;;

              ip)
                MAC=$($0 mac)
                # shellcheck disable=SC2001
                MAC1=$(sed -e 's/0\([[:digit:]]\)/\1/g' <<< "$MAC")
                IP=
                while [ -z "$IP" ]; do
                  IP=$(arp -a | sed -ne "s/.*(\([0-9.]*\)) at $MAC1.*/\1/p")
                  sleep 1
                done
                echo "$IP"
                ;;

              update)
                shift
                NIX_PATCH=$1

                # CREATE TEMPORARY FILES
                PLIST_JSON=$(mktemp -u)
                PLIST_JSON_PLIST=$(mktemp -u)
                JSON_PATCH=$(mktemp -u)
                trap 'rm $PLIST_JSON $PLIST_JSON_PLIST $JSON_PATCH' EXIT

                # EXECUTE UPDATE
                nix eval -f "$NIX_PATCH" --json > "$JSON_PATCH"
                plutil -convert json -o "$PLIST_JSON" "$PLIST_FILE"
                jq -s 'reduce .[] as $item ({}; . * $item)' "$PLIST_JSON" "$JSON_PATCH" > "$PLIST_JSON_PLIST"
                plutil -convert binary1 "$PLIST_JSON_PLIST"

                # WRITE UPDATE TO CONFIG
                cp "$PLIST_JSON_PLIST" "$PLIST_FILE"
                ;;


              usage | *)
                SCRIPT=$(basename "$0")
                echo "usage: VM_NAME=your-vm $SCRIPT show"
                echo "usage: VM_NAME=your-vm $SCRIPT mac"
                echo "usage: VM_NAME=your-vm $SCRIPT ip"
                echo "usage: VM_NAME=your-vm $SCRIPT update patch-config.nix"
                ;;
            esac
          '';
        };
        packages.nixosDeploy = pkgs.writeShellApplication {
          name = "nixosDeploy";
          runtimeInputs = [
            self'.packages.utmConfiguration
            pkgs.nixos-rebuild
          ];
          text = ''
            set -x
            FLAKE_CONFIG=$1
            shift
            THE_TARGET="root@$(utmConfiguration ip)"
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
            inherit (self'.packages) nixosCreate sshNixos utm nixosCmd utmConfiguration;
            inherit (pkgs) coreutils nixos-rebuild nixos-anywhere;
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
