{ pkgs, lib, config, modulesPath, ... }:


{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];

  config = {
    ec2.hvm = true;
    time.timeZone = "Europe/Berlin";
    networking.hostName = "import-blocks";
    # services.tailscale.enable = true;
    # networking.firewall.trustedInterfaces = [ "tailscale0" ];

    security.auditd.enable = true;
    security.audit.enable = true;
    security.audit.rules = [
      "-a exit,always -F arch=b64 -S execve"
    ];

    nix.trustedUsers = [ "root" "@wheel" ];
    security.sudo.enable = true;
    security.sudo.wheelNeedsPassword = false;

    nix.autoOptimiseStore = true;

    users.users.root.openssh.authorizedKeys.keys = [];


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

    systemd.services.import-blocks = {
      description = "import-block poller";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        ARWEAVE_DOTENV_PATH = "/var/dotenv";
      };

      script = ''
        ${pkgs.import-blocks-wrapped}/bin/import-blocks
      '';

      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = 0;
        KillSignal = "SIGINT";
      };
    };
  };
}
