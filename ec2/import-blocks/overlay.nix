final: prev: {
  import-blocks = (import ./package-lock.nix prev)."@arweave/import-blocks";
  import-blocks-wrapped = prev.writeShellScriptBin "import-blocks" ''
    cd ${final.import-blocks}/lib/node_modules/@arweave/import-blocks
    ${prev.bash}/bin/bash /etc/ec2-metadata/user-data
    ${prev.nodejs_latest}/bin/node src/index.mjs
  '';

}
