> [!NOTE]
>
> My newer project [ciderale/nixos-lima](https://github.com/ciderale/nixos-lima) also aims
> for running NixOS VMs on MacOS, but using [lima-vm.io](https://lima-vm.io) instead of UTM.
> The result is a cleaner and better configurable, declarative VM setup with the same goals.
> I recommend using [ciderale/nixos-lima](https://github.com/ciderale/nixos-lima).

# NixOS-UTM : Conveniently create UTM VM with NixOS

This repository provides a small wrapper around [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
to automate creation of NixOS VMs on MacOS hosts using [UTM](https://mac.getutm.app)
with the Apple virtualization backend (supporting Rosetta2).

Using the apple virtualsation (insted of qemu) provides access to Rosetta2 and
thus efficient `x86_64` support within the VM. Unfortunately, the `utmctl` does
not yet provide full functionality (e.g. `ip-address`) for the appble backend.
That complicates automatic vm creation and this repo provides utilities to
automate as much as possible for a simple automation setup.

## How to create a VM

- create a nix flake with a nixosConfiguration defined
	- the ./example folder provides a flake with minimal example config
	- use it with `nix flake new -t github:ciderale/nixos-utm my-utm-vm`
	- adjust ./configuration.nix (atleast set your ssh public key)
- define an environment variable VM_NAME to name the UTM VM
	- maybe configure this env var within your project/system setup
- (optionally) define an environment variable UTM_CONFIG to set UTM VM parameters
	- fallback to UTM_CONFIG=./utm.config.nix (which is merged using plutil)
- kickoff the installation process with the following command
	- assuming your flake is the current directory `.` with config `utm`

```
export VM_NAME=myVM
nix run github:ciderale/nixos-utm#nixosCreate .#utm
```

## Retrieve the VMs IP/Mac address and other UTM configuration 

```
VM_NAME=myVM nix run github:ciderale/nixos-utm#utmConfiguration ip
```

This command uses the arp cache to lookup the ip address based on the mac
address that is found in the VMs configuration folder.

The command `utmConfiguration` alone provides usage for other UTM configuration related information

## How to rebuild the configuration for an existing configuration

```
VM_NAME=myVM nix run github:ciderale/nixos-utm#nixosDeploy .#utm
```

## Some aspects that can be improved

- Make VM configuration configurable (currently hardcoded in nixosCreate)
- Improve example configuration for simpler onboarding
- Provide utility to deploy an updated configuration
- Directory sharing between VM and host system.
	- it's a UTM system configuration, not a VM configuration
	- uses some binary coded "bookmark" format
