inputs:
inputs.nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";
  modules = [
    inputs.disko.nixosModules.disko
    ./base.nix
    ./configuration.nix
    ./disk-config.nix
    ./hardware-configuration.nix
  ];
}
