inputs:
inputs.nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";
  modules = [
    inputs.disko.nixosModules.disko
    {disko.devices.disk.disk1.device = "/dev/vda";}
    ./configuration.nix
  ];
}
