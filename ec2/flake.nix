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
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }:

    let
      system = "x86_64-linux";
      pkgs = (import nixpkgs {
        inherit overlays system;
        config = { allowUnfree = true; };
      });
      overlays = [ (import ./import-blocks/overlay.nix) ];

    in {
      packages.x86_64-linux = {
        import-blocks = nixos-generators.nixosGenerate {
          inherit pkgs;
          modules = [
            ./base.nix
            ./import-blocks/module.nix
          ];
          format = "amazon";
        };
      };
    };
}
