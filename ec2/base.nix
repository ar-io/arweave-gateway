{ config, lib, pkgs, ... }:

{

  imports = [ ];

  config = {
    nix.autoOptimiseStore = true;
    users.users.root.openssh.authorizedKeys.keys = [];
    services.tailscale.enable = true;
    networking.firewall.trustedInterfaces = [ "tailscale0" ];

    # Tell the firewall to implicitly trust packets routed over Tailscale:
    # config.
    security.auditd.enable = true;
    security.audit.enable = true;
    security.audit.rules = [
      "-a exit,always -F arch=b64 -S execve"
    ];

    nix.trustedUsers = [ "root" "@wheel" ];
    security.sudo.enable = true;
    security.sudo.wheelNeedsPassword = false;
    environment.defaultPackages = lib.mkForce [];

    services.openssh = {
      passwordAuthentication = false;
      allowSFTP = false; # Don't set this if you need sftp
      challengeResponseAuthentication = false;
      extraConfig = ''
        AllowTcpForwarding yes
        X11Forwarding no
        AllowAgentForwarding no
        AllowStreamLocalForwarding no
        AuthenticationMethods publickey
     '';
    };

    # PCI compliance
    environment.systemPackages = with pkgs; [ clamav ];

  };
}
