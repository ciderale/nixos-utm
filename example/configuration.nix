{
  modulesPath,
  lib,
  pkgs,
  ...
}: {
  environment.systemPackages = map lib.lowPrio [
    pkgs.curl
    pkgs.gitMinimal
  ];

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPKyKsE4eCn8BDnJZNmFttaCBmVUhO73qmhguEtNft6y"
  ];

  system.stateVersion = "23.11";
}
