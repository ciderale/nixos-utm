{modulesPath, ...}: {
  disko.devices.disk.disk1.device = "/dev/vda";
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];
  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
}
