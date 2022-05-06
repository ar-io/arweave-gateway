/**
 * Arweave Gateway
 * Copyright (C) 2022 Permanent Data Solutions, Inc
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

{
  name = "@ar.io/import-bundles";
  version = "1.0.0";
  main = "src/index.mjs";

  dependencies = {
    arbundles     = "^0.6.16";
    async-retry   = "^1.3.3";
    aws-sdk       = "^2.1046.0";
    dotenv        = "^10.0.0";
    exit-hook     = "^3.0.0";
    got           = "^12.0.0";
    knex          = "^0.95.14";
    moment        = "latest";
    pg            = "^8.7.1";
    p-limit       = "^4.0.0";
    p-wait-for    = "^4.1.0";
    p-whilst      = "^3.0.0";
    p-min-delay   = "^4.0.1";
    ramda         = "^0.27.1";
    sqs-consumer  = "^5.6.0";
    winston       = "^3.6.0";
  };

  resolutions = {
    "arweave-stream-tx@*" = "arweave-stream-tx@^1.1.0";
    "avsc@*" = "avsc@^5.x";
  };

  packageDerivation = { jsnixDeps, ... }@pkgs: {
    buildInputs = [
      pkgs.openssl
      pkgs.makeWrapper
    ];

  postInstall = ''
    mkdir -p $out/bin
    mkdir -p $out/lib/node_modules/@ar.io/import-bundles

    cp -rT $(pwd) $out/lib/node_modules/@ar.io/import-bundles
    makeWrapper ${pkgs.nodejs_latest}/bin/node $out/bin/import-bundles-start \
      --run "cd $out/lib/node_modules/@ar.io/import-bundles" \
      --add-flags src/index.mjs \
      --prefix NODE_ENV : production \
      --prefix NODE_PATH : "./node_modules"
    '';
  };
}
