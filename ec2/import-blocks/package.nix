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
  name = "@ar.io/import-blocks";
  version = "1.0.0";
  main = "src/index.mjs";

  dependencies = {
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
  };
  packageDerivation = { jsnixDeps, ... }@pkgs: {
    buildInputs = [  ];
    # buildPhase = "tsc --build tsconfig.json";
  };
}
