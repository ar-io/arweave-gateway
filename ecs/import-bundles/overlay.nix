final: prev:

let packageLock = (import ./package-lock.nix prev);
in {
  inherit (packageLock) "@arweave/import-bundles";

  importBundlesDocker = prev.dockerTools.buildLayeredImage {
    name = "import-bundles";
    tag = "latest";
    created = "now";
    extraCommands = "mkdir -m 0777 tmp";
    config = {
      User = "1000:1000";
      Cmd = [ "${final."@arweave/import-bundles"}/bin/import-bundles-start" ];
      ExposedPorts = {
        "3000" = {};
      };
    };
  };
}
