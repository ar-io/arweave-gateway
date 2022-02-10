{pkgs, stdenv, lib, nodejs, fetchurl, fetchgit, fetchFromGitHub, jq, makeWrapper, python3, runCommand, runCommandCC, xcodebuild, ... }:

let
  packageNix = import ./package.nix;
  copyNodeModules = {dependencies ? [] }:
    (lib.lists.foldr (dep: acc:
      let pkgName = if (builtins.hasAttr "packageName" dep)
                    then dep.packageName else dep.name;
      in
      acc + ''
      if [[ ! -f "node_modules/${pkgName}" && \
            ! -d "node_modules/${pkgName}" && \
            ! -L "node_modules/${pkgName}" && \
            ! -e "node_modules/${pkgName}" ]]
     then
       mkdir -p "node_modules/${pkgName}"
       cp -rLT "${dep}/lib/node_modules/${pkgName}" "node_modules/${pkgName}"
       chmod -R +rw "node_modules/${pkgName}"
     fi
     '')
     "" dependencies);
  linkNodeModules = {dependencies ? [], extraDependencies ? []}:
    (lib.lists.foldr (dep: acc:
      let pkgName = if (builtins.hasAttr "packageName" dep)
                    then dep.packageName else dep.name;
      in (acc + (lib.optionalString
      ((lib.findSingle (px: px.packageName == dep.packageName) "none" "found" extraDependencies) == "none")
      ''
      if [[ ! -f "node_modules/${pkgName}" && \
            ! -d "node_modules/${pkgName}" && \
            ! -L "node_modules/${pkgName}" && \
            ! -e "node_modules/${pkgName}" ]]
     then
       mkdir -p "node_modules/${pkgName}"
       ln -s "${dep}/lib/node_modules/${pkgName}"/* "node_modules/${pkgName}"
       ${lib.optionalString (builtins.hasAttr "dependencies" dep)
         ''
         rm -rf "node_modules/${pkgName}/node_modules"
         (cd node_modules/${dep.packageName}; ${linkNodeModules { inherit (dep) dependencies; inherit extraDependencies;}})
         ''}
     fi
     '')))
     "" dependencies);
  gitignoreSource = 
    (import (fetchFromGitHub {
      owner = "hercules-ci";
      repo = "gitignore.nix";
      rev = "5b9e0ff9d3b551234b4f3eb3983744fa354b17f1";
      sha256 = "o/BdVjNwcB6jOmzZjOH703BesSkkS5O7ej3xhyO8hAY=";
    }) { inherit lib; }).gitignoreSource;
  transitiveDepInstallPhase = {dependencies ? [], pkgName}: ''
    export packageDir="$(pwd)"
    mkdir -p $out/lib/node_modules/${pkgName}
    cd $out/lib/node_modules/${pkgName}
    cp -rfT "$packageDir" "$(pwd)"
    ${copyNodeModules { inherit dependencies; }} '';
  transitiveDepUnpackPhase = {dependencies ? [], pkgName}: ''
     unpackFile "$src";
     # not ideal, but some perms are fubar
     chmod -R +777 . || true
     packageDir="$(find . -maxdepth 1 -type d | tail -1)"
     cd "$packageDir"
   '';
  getNodeDep = packageName: dependencies:
    (let depList = if ((builtins.typeOf dependencies) == "set")
                  then (builtins.attrValues dependencies)
                  else dependencies;
    in (builtins.head
        (builtins.filter (p: p.packageName == packageName) depList)));
  nodeSources = runCommand "node-sources" {} ''
    tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
    mv node-* $out
  '';
  linkBins = ''
    ${goBinLink}/bin/bin-link
'';
  flattenScript = args: '' ${goFlatten}/bin/flatten ${args}'';
  sanitizeName = nm: lib.strings.sanitizeDerivationName
    (builtins.replaceStrings [ "@" "/" ] [ "_at_" "_" ] nm);
  jsnixDrvOverrides = { drv_, jsnixDeps, dedupedDeps, isolateDeps }:
    let drv = drv_ (pkgs // { inherit nodejs copyNodeModules gitignoreSource jsnixDeps nodeModules getNodeDep; });
        skipUnpackFor = if (builtins.hasAttr "skipUnpackFor" drv)
                        then drv.skipUnpackFor else [];
        copyUnpackFor = if (builtins.hasAttr "copyUnpackFor" drv)
                        then drv.copyUnpackFor else [];
        pkgJsonFile = runCommand "package.json" { buildInputs = [jq]; } ''
          echo ${toPackageJson { inherit jsnixDeps; extraDeps = (if (builtins.hasAttr "extraDependencies" drv) then drv.extraDependencies else []); }} > $out
          cat <<< $(cat $out | jq) > $out
        '';
        copyDeps = builtins.attrValues jsnixDeps;
        copyDepsStr = builtins.concatStringsSep " " (builtins.map (dep: if (builtins.hasAttr "packageName" dep) then dep.packageName else dep.name) copyDeps);
        extraDeps = (builtins.map (dep: if (builtins.hasAttr "packageName" dep) then dep.packageName else dep.name)
                      (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies));
        extraDepsStr = builtins.concatStringsSep " " extraDeps;
        buildDepDep = lib.lists.unique (lib.lists.concatMap (d: d.buildInputs)
                        (copyDeps ++ (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies)));
        nodeModules = runCommandCC "${sanitizeName packageNix.name}_node_modules"
          { buildInputs = [nodejs] ++ buildDepDep;
            fixupPhase = "true";
            doCheck = false;
            doInstallCheck = false;
            version = builtins.hashString "sha512" (lib.strings.concatStrings copyDeps); }
         ''
           echo 'unpack dependencies...'
           mkdir -p $out/lib/node_modules
           cd $out/lib
           ${linkNodeModules { dependencies = builtins.attrValues isolateDeps; }}
           ${copyNodeModules {
                dependencies = copyDeps;
           }}
           ${copyNodeModules {
                dependencies = builtins.attrValues dedupedDeps;
           }}
           chmod -R +rw node_modules
           ${copyNodeModules {
                dependencies = (lib.optionals (builtins.hasAttr "extraDependencies" drv) drv.extraDependencies);
           }}
           ${lib.optionalString ((builtins.length extraDeps) > 0) "echo 'resolving incoming transient deps of ${extraDepsStr}...'"}
           ${lib.optionalString ((builtins.length extraDeps) > 0) (flattenScript extraDepsStr)}
           ${lib.optionalString (builtins.hasAttr "nodeModulesUnpack" drv) drv.nodeModulesUnpack}
           echo 'link nodejs bins to out-dir...'
           ${linkBins}
        '';
    in stdenv.mkDerivation (drv // {
      passthru = { inherit nodeModules pkgJsonFile; };
      version = packageNix.version;
      name = sanitizeName packageNix.name;
      preUnpackBan_ = mkPhaseBan "preUnpack" drv;
      unpackBan_ = mkPhaseBan "unpackPhase" drv;
      postUnpackBan_ = mkPhaseBan "postUnpack" drv;
      preConfigureBan_ = mkPhaseBan "preConfigure" drv;
      configureBan_ = mkPhaseBan "configurePhase" drv;
      postConfigureBan_ = mkPhaseBan "postConfigure" drv;
      src = if (builtins.hasAttr "src" packageNix) then packageNix.src else gitignoreSource ./.;
      packageName = packageNix.name;
      doStrip = false;
      doFixup = false;
      doUnpack = true;
      NODE_PATH = "./node_modules";
      buildInputs = [ nodejs jq ] ++ lib.optionals (builtins.hasAttr "buildInputs" drv) drv.buildInputs;

      configurePhase = ''
        ln -s ${nodeModules}/lib/node_modules node_modules
        cat ${pkgJsonFile} > package.json
      '';
      buildPhase = ''
        runHook preBuild
       ${lib.optionalString (builtins.hasAttr "buildPhase" drv) drv.buildPhase}
       runHook postBuild
      '';
      installPhase =  ''
          runHook preInstall
          mkdir -p $out/lib/node_modules/${packageNix.name}
          cp -rfT ./ $out/lib/node_modules/${packageNix.name}
          runHook postInstall
       '';
  });
  toPackageJson = { jsnixDeps ? {}, extraDeps ? [] }:
    let
      main = if (builtins.hasAttr "main" packageNix) then packageNix else throw "package.nix is missing main attribute";
      pkgName = if (builtins.hasAttr "packageName" packageNix)
                then packageNix.packageName else packageNix.name;
      packageNixDeps = if (builtins.hasAttr "dependencies" packageNix)
                       then packageNix.dependencies
                       else {};
      extraDeps_ = lib.lists.foldr (dep: acc: { "${dep.packageName}" = dep; } // acc) {} extraDeps;
      allDeps = extraDeps_ // packageNixDeps;
      prodDeps = lib.lists.foldr
        (depName: acc: acc // {
          "${depName}" = (if ((builtins.typeOf allDeps."${depName}") == "string")
                          then allDeps."${depName}"
                          else
                            if (((builtins.typeOf allDeps."${depName}") == "set") &&
                                ((builtins.typeOf allDeps."${depName}".version) == "string"))
                          then allDeps."${depName}".version
                          else "latest");}) {} (builtins.attrNames allDeps);
      safePkgNix = lib.lists.foldr (key: acc:
        if ((builtins.typeOf packageNix."${key}") != "lambda")
        then (acc // { "${key}" =  packageNix."${key}"; })
        else acc)
        {} (builtins.attrNames packageNix);
    in lib.strings.escapeNixString
      (builtins.toJSON (safePkgNix // { dependencies = prodDeps; name = pkgName; }));
  mkPhaseBan = phaseName: usrDrv:
      if (builtins.hasAttr phaseName usrDrv) then
      throw "jsnix error: using ${phaseName} isn't supported at this time"
      else  "";
  mkPhase = pkgs_: {phase, pkgName}:
     lib.optionalString ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                         (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                         (builtins.hasAttr "${phase}" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."${phase}" == "string"
       then
         packageNix.dependencies."${pkgName}"."${phase}"
       else
         (packageNix.dependencies."${pkgName}"."${phase}" (pkgs_ // { inherit getNodeDep; })));
  mkExtraBuildInputs = pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                    (builtins.hasAttr "extraBuildInputs" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."extraBuildInputs" == "list"
       then
         packageNix.dependencies."${pkgName}"."extraBuildInputs"
       else
         (packageNix.dependencies."${pkgName}"."extraBuildInputs" (pkgs_ // { inherit getNodeDep; })));
  mkExtraDependencies = pkgs_: {pkgName}:
     lib.optionals ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
                    (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
                    (builtins.hasAttr "extraDependencies" packageNix.dependencies."${pkgName}"))
      (if builtins.typeOf packageNix.dependencies."${pkgName}"."extraDependencies" == "list"
       then
         packageNix.dependencies."${pkgName}"."extraDependencies"
       else
         (packageNix.dependencies."${pkgName}"."extraDependencies" (pkgs_ // { inherit getNodeDep; })));
  mkUnpackScript = { dependencies ? [], extraDependencies ? [], pkgName }:
     let copyNodeDependencies =
       if ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
           (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
           (builtins.hasAttr "copyNodeDependencies" packageNix.dependencies."${pkgName}") &&
           (builtins.typeOf packageNix.dependencies."${pkgName}"."copyNodeDependencies" == "bool") &&
           (packageNix.dependencies."${pkgName}"."copyNodeDependencies" == true))
       then true else false;
     in ''
      ${copyNodeModules { dependencies = dependencies ++ extraDependencies; }}
      chmod -R +rw $(pwd)
    '';
  mkBuildScript = { dependencies ? [], pkgName }:
    let extraNpmFlags =
      if ((builtins.hasAttr "${pkgName}" packageNix.dependencies) &&
          (builtins.typeOf packageNix.dependencies."${pkgName}" == "set") &&
          (builtins.hasAttr "npmFlags" packageNix.dependencies."${pkgName}") &&
          (builtins.typeOf packageNix.dependencies."${pkgName}"."npmFlags" == "string"))
      then packageNix.dependencies."${pkgName}"."npmFlags" else "";
    in ''
      runHook preBuild
      export HOME=$TMPDIR
      npm --offline config set node_gyp ${nodejs}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
      npm --offline config set omit dev
      NODE_PATH="$(pwd)/node_modules:$NODE_PATH" \
      npm --offline --nodedir=${nodeSources} --location="$(pwd)" \
          ${extraNpmFlags} "--production" "--preserve-symlinks" \
          rebuild --build-from-source
      runHook postBuild
    '';
  mkInstallScript = { pkgName }: ''
      runHook preInstall
      export packageDir="$(pwd)"
      mkdir -p $out/lib/node_modules/${pkgName}
      cd $out/lib/node_modules/${pkgName}
      cp -rfT "$packageDir" "$(pwd)"
      if [[ -d "$out/lib/node_modules/${pkgName}/bin" ]]
      then
         mkdir -p $out/bin
         ln -s "$out/lib/node_modules/${pkgName}/bin"/* $out/bin
      fi
      cd $out/lib/node_modules/${pkgName}
      runHook postInstall
    '';
  goBinLink = pkgs.buildGoModule {
  pname = "bin-link";
  version = "0.0.0";
  vendorSha256 = null;
  buildInputs = [ pkgs.nodejs ];
  src = pkgs.fetchFromGitHub {
    owner = "hlolli";
    repo = "jsnix";
    rev = "a66cf91ad49833ef3d84064c1037d942c97838bb";
    sha256 = "AvDZXUSxuJa5lZ7zRdXWIDYTYfbH2VfpuHbvZBrT9f0=";
  };
  preBuild = ''
    cd go/bin-link
  '';
};
  goFlatten = pkgs.buildGoModule {
  pname = "flatten";
  version = "0.0.0";
  vendorSha256 = null;
  buildInputs = [ pkgs.nodejs ];
  src = pkgs.fetchFromGitHub {
    owner = "hlolli";
    repo = "jsnix";
    rev = "a66cf91ad49833ef3d84064c1037d942c97838bb";
    sha256 = "AvDZXUSxuJa5lZ7zRdXWIDYTYfbH2VfpuHbvZBrT9f0=";
  };
  preBuild = ''
    cd go/flatten
  '';
};
  sources = rec {
    "@sindresorhus/is-4.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_sindresorhus_slash_is";
      packageName = "@sindresorhus/is";
      version = "4.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@sindresorhus/is"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@sindresorhus/is"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@sindresorhus/is/-/is-4.2.0.tgz";
        sha512 = "VkE3KLBmJwcCaVARtQpfuKcKv8gcBmUubrfHGF84dXuuW6jgsRYxPtzcIhPyK9WAPpRt2/xY6zkD9MnRaJzSyw==";
      };
    };
    "@szmarczak/http-timer-5.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_szmarczak_slash_http-timer";
      packageName = "@szmarczak/http-timer";
      version = "5.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@szmarczak/http-timer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@szmarczak/http-timer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@szmarczak/http-timer/-/http-timer-5.0.1.tgz";
        sha512 = "+PmQX0PiAYPMeVYe237LJAYvOMYW1j2rH5YROyS3b4CTVJum34HfRvKvAzozHAQG0TnHNdUfY9nCeUyRAs//cw==";
      };
    };
    "@types/cacheable-request-6.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_cacheable-request";
      packageName = "@types/cacheable-request";
      version = "6.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/cacheable-request"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/cacheable-request"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/cacheable-request/-/cacheable-request-6.0.2.tgz";
        sha512 = "B3xVo+dlKM6nnKTcmm5ZtY/OL8bOAOd2Olee9M1zft65ox50OzjEHW91sDiU9j6cvW8Ejg1/Qkf4xd2kugApUA==";
      };
    };
    "@types/http-cache-semantics-4.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_http-cache-semantics";
      packageName = "@types/http-cache-semantics";
      version = "4.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/http-cache-semantics"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/http-cache-semantics"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/http-cache-semantics/-/http-cache-semantics-4.0.1.tgz";
        sha512 = "SZs7ekbP8CN0txVG2xVRH6EgKmEm31BOxA07vkFaETzZz1xh+cbt8BcI0slpymvwhx5dlFnQG2rTlPVQn+iRPQ==";
      };
    };
    "@types/keyv-3.1.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_keyv";
      packageName = "@types/keyv";
      version = "3.1.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/keyv"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/keyv"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/keyv/-/keyv-3.1.3.tgz";
        sha512 = "FXCJgyyN3ivVgRoml4h94G/p3kY+u/B86La+QptcqJaWtBWtmc6TtkNfS40n9bIvyLteHh7zXOtgbobORKPbDg==";
      };
    };
    "@types/node-17.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_node";
      packageName = "@types/node";
      version = "17.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/node"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/node"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/node/-/node-17.0.2.tgz";
        sha512 = "JepeIUPFDARgIs0zD/SKPgFsJEAF0X5/qO80llx59gOxFTboS9Amv3S+QfB7lqBId5sFXJ99BN0J6zFRvL9dDA==";
      };
    };
    "@types/responselike-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_responselike";
      packageName = "@types/responselike";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/responselike"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/responselike"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/responselike/-/responselike-1.0.0.tgz";
        sha512 = "85Y2BjiufFzaMIlvJDvTTB8Fxl2xfLo4HgmHzVBz08w4wDePCTjYw66PdrolO0kzli3yam/YCgRufyo1DdQVTA==";
      };
    };
    "base64-js-1.5.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "base64-js";
      packageName = "base64-js";
      version = "1.5.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "base64-js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "base64-js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/base64-js/-/base64-js-1.5.1.tgz";
        sha512 = "AKpaYlHn8t4SVbOHCy+b5+KKgvR4vrsD8vbvrbiQJps7fKDTkjkDry6ji0rUJjC0kzbNePLwzxq8iypo41qeWA==";
      };
    };
    "buffer-4.9.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "buffer";
      packageName = "buffer";
      version = "4.9.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "buffer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "buffer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/buffer/-/buffer-4.9.2.tgz";
        sha512 = "xq+q3SRMOxGivLhBNaUdC64hDTQwejJ+H0T/NB1XMtTVEwNTrfFF3gAxiyW0Bu/xWEGhjVKgUcMhCrUy2+uCWg==";
      };
    };
    "buffer-writer-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "buffer-writer";
      packageName = "buffer-writer";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "buffer-writer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "buffer-writer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/buffer-writer/-/buffer-writer-2.0.0.tgz";
        sha512 = "a7ZpuTZU1TRtnwyCNW3I5dc0wWNC3VR9S++Ewyk2HHZdrO3CQJqSpd+95Us590V6AL7JqUAH2IwZ/398PmNFgw==";
      };
    };
    "cacheable-lookup-6.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "cacheable-lookup";
      packageName = "cacheable-lookup";
      version = "6.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "cacheable-lookup"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "cacheable-lookup"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/cacheable-lookup/-/cacheable-lookup-6.0.4.tgz";
        sha512 = "mbcDEZCkv2CZF4G01kr8eBd/5agkt9oCqz75tJMSIsquvRZ2sL6Hi5zGVKi/0OSC9oO1GHfJ2AV0ZIOY9vye0A==";
      };
    };
    "cacheable-request-7.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "cacheable-request";
      packageName = "cacheable-request";
      version = "7.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "cacheable-request"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "cacheable-request"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/cacheable-request/-/cacheable-request-7.0.2.tgz";
        sha512 = "pouW8/FmiPQbuGpkXQ9BAPv/Mo5xDGANgSNXzTzJ8DrKGuXOssM4wIQRjfanNRh3Yu5cfYPvcorqbhg2KIJtew==";
      };
    };
    "clone-response-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "clone-response";
      packageName = "clone-response";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "clone-response"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "clone-response"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/clone-response/-/clone-response-1.0.2.tgz";
        sha1 = "d1dc973920314df67fbeb94223b4ee350239e96b";
      };
    };
    "colorette-2.0.16" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "colorette";
      packageName = "colorette";
      version = "2.0.16";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "colorette"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "colorette"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/colorette/-/colorette-2.0.16.tgz";
        sha512 = "hUewv7oMjCp+wkBv5Rm0v87eJhq4woh5rSR+42YSQJKecCqgIqNkZ6lAlQms/BwHPJA5NKMRlpxPRv0n8HQW6g==";
      };
    };
    "commander-7.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "commander";
      packageName = "commander";
      version = "7.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "commander"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "commander"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/commander/-/commander-7.2.0.tgz";
        sha512 = "QrWXB+ZQSVPmIWIhtEO9H+gwHaMGYiF5ChvoJ+K9ZGHG/sVsa6yiesAD1GC/x46sET00Xlwo1u49RVVVzvcSkw==";
      };
    };
    "debug-4.3.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "debug";
      packageName = "debug";
      version = "4.3.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "debug"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "debug"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/debug/-/debug-4.3.2.tgz";
        sha512 = "mOp8wKcvj7XxC78zLgw/ZA+6TSgkoE2C/ienthhRD298T7UNwAg9diBpLRxC0mOezLl4B0xV7M0cCO6P/O0Xhw==";
      };
    };
    "debug-4.3.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "debug";
      packageName = "debug";
      version = "4.3.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "debug"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "debug"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/debug/-/debug-4.3.3.tgz";
        sha512 = "/zxw5+vh1Tfv+4Qn7a5nsbcJKPaSvCDhojn6FEl9vupwK2VCSDtEiEtqr8DFtzYFOdz63LBkxec7DYuc2jon6Q==";
      };
    };
    "decompress-response-6.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "decompress-response";
      packageName = "decompress-response";
      version = "6.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "decompress-response"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "decompress-response"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/decompress-response/-/decompress-response-6.0.0.tgz";
        sha512 = "aW35yZM6Bb/4oJlZncMH2LCoZtJXTRxES17vE3hoRiowU2kWHaJKFkSBDnDR+cm9J+9QhXmREyIfv0pji9ejCQ==";
      };
    };
    "defer-to-connect-2.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "defer-to-connect";
      packageName = "defer-to-connect";
      version = "2.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "defer-to-connect"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "defer-to-connect"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/defer-to-connect/-/defer-to-connect-2.0.1.tgz";
        sha512 = "4tvttepXG1VaYGrRibk5EwJd1t4udunSOVMdLSAL6mId1ix438oPwPZMALY41FCijukO1L0twNcGsdzS7dHgDg==";
      };
    };
    "end-of-stream-1.4.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "end-of-stream";
      packageName = "end-of-stream";
      version = "1.4.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "end-of-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "end-of-stream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/end-of-stream/-/end-of-stream-1.4.4.tgz";
        sha512 = "+uw1inIHVPQoaVuHzRyXd21icM+cnt4CzD5rW+NC1wjOUSTOs+Te7FOv7AhN7vS9x/oIyhLP5PR1H+phQAHu5Q==";
      };
    };
    "escalade-3.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "escalade";
      packageName = "escalade";
      version = "3.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "escalade"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "escalade"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/escalade/-/escalade-3.1.1.tgz";
        sha512 = "k0er2gUkLf8O0zKJiAhmkTnJlTvINGv7ygDNPbeIsX/TJjGJZHuh9B2UxbsaEkmlEo9MfhrSzmhIlhRlI2GXnw==";
      };
    };
    "esm-3.2.25" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "esm";
      packageName = "esm";
      version = "3.2.25";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "esm"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "esm"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/esm/-/esm-3.2.25.tgz";
        sha512 = "U1suiZ2oDVWv4zPO56S0NcR5QriEahGtdN2OR6FiOG4WJvcjBVFB0qI4+eKoWFH483PKGuLuu6V8Z4T5g63UVA==";
      };
    };
    "events-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "events";
      packageName = "events";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "events"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "events"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/events/-/events-1.1.1.tgz";
        sha1 = "9ebdb7635ad099c70dcc4c2a1f5004288e8bd924";
      };
    };
    "form-data-encoder-1.7.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "form-data-encoder";
      packageName = "form-data-encoder";
      version = "1.7.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "form-data-encoder"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "form-data-encoder"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/form-data-encoder/-/form-data-encoder-1.7.1.tgz";
        sha512 = "EFRDrsMm/kyqbTQocNvRXMLjc7Es2Vk+IQFx/YW7hkUH1eBl4J1fqiP34l74Yt0pFLCNpc06fkbVk00008mzjg==";
      };
    };
    "function-bind-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "function-bind";
      packageName = "function-bind";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "function-bind"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "function-bind"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/function-bind/-/function-bind-1.1.1.tgz";
        sha512 = "yIovAzMX49sF8Yl58fSCWJ5svSLuaibPxXQJFLmBObTuCr0Mf1KiPopGM9NiFjiYBCbfaa2Fh6breQ6ANVTI0A==";
      };
    };
    "get-stream-5.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "get-stream";
      packageName = "get-stream";
      version = "5.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "get-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "get-stream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/get-stream/-/get-stream-5.2.0.tgz";
        sha512 = "nBF+F1rAZVCu/p7rjzgA+Yb4lfYXrpl7a6VmJrU8wF9I1CKvP/QwPNZHnOlwbTkY6dvtFIzFMSyQXbLoTQPRpA==";
      };
    };
    "get-stream-6.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "get-stream";
      packageName = "get-stream";
      version = "6.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "get-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "get-stream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/get-stream/-/get-stream-6.0.1.tgz";
        sha512 = "ts6Wi+2j3jQjqi70w5AlN8DFnkSwC+MqmxEzdEALB2qXZYV3X/b1CTfgPLGJNMeAWxdPfU8FO1ms3NUfaHCPYg==";
      };
    };
    "getopts-2.2.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "getopts";
      packageName = "getopts";
      version = "2.2.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "getopts"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "getopts"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/getopts/-/getopts-2.2.5.tgz";
        sha512 = "9jb7AW5p3in+IiJWhQiZmmwkpLaR/ccTWdWQCtZM66HJcHHLegowh4q4tSD7gouUyeNvFWRavfK9GXosQHDpFA==";
      };
    };
    "has-1.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "has";
      packageName = "has";
      version = "1.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "has"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/has/-/has-1.0.3.tgz";
        sha512 = "f2dvO0VU6Oej7RkWJGrehjbzMAjFp5/VKPp5tTpWIV4JHHZK1/BxbFRtf/siA2SWTe09caDmVtYYzWEIbBS4zw==";
      };
    };
    "http-cache-semantics-4.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "http-cache-semantics";
      packageName = "http-cache-semantics";
      version = "4.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "http-cache-semantics"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "http-cache-semantics"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/http-cache-semantics/-/http-cache-semantics-4.1.0.tgz";
        sha512 = "carPklcUh7ROWRK7Cv27RPtdhYhUsela/ue5/jKzjegVvXDqM2ILE9Q2BGn9JZJh1g87cp56su/FgQSzcWS8cQ==";
      };
    };
    "http2-wrapper-2.1.10" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "http2-wrapper";
      packageName = "http2-wrapper";
      version = "2.1.10";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "http2-wrapper"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "http2-wrapper"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/http2-wrapper/-/http2-wrapper-2.1.10.tgz";
        sha512 = "QHgsdYkieKp+6JbXP25P+tepqiHYd+FVnDwXpxi/BlUcoIB0nsmTOymTNvETuTO+pDuwcSklPE72VR3DqV+Haw==";
      };
    };
    "ieee754-1.1.13" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ieee754";
      packageName = "ieee754";
      version = "1.1.13";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ieee754"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ieee754"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/ieee754/-/ieee754-1.1.13.tgz";
        sha512 = "4vf7I2LYV/HaWerSo3XmlMkp5eZ83i+/CDluXi/IGTs/O1sejBNhTtnxzmRZfvOUqj7lZjqHkeTvpgSFDlWZTg==";
      };
    };
    "interpret-2.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "interpret";
      packageName = "interpret";
      version = "2.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "interpret"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "interpret"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/interpret/-/interpret-2.2.0.tgz";
        sha512 = "Ju0Bz/cEia55xDwUWEa8+olFpCiQoypjnQySseKtmjNrnps3P+xfpUmGr90T7yjlVJmOtybRvPXhKMbHr+fWnw==";
      };
    };
    "is-core-module-2.8.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-core-module";
      packageName = "is-core-module";
      version = "2.8.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-core-module"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-core-module"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-core-module/-/is-core-module-2.8.0.tgz";
        sha512 = "vd15qHsaqrRL7dtH6QNuy0ndJmRDrS9HAM1CAiSifNUFv4x1a0CCVsj18hJ1mShxIG6T2i1sO78MkP56r0nYRw==";
      };
    };
    "isarray-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "isarray";
      packageName = "isarray";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "isarray"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "isarray"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/isarray/-/isarray-1.0.0.tgz";
        sha1 = "bb935d48582cba168c06834957a54a3e07124f11";
      };
    };
    "jmespath-0.15.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "jmespath";
      packageName = "jmespath";
      version = "0.15.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "jmespath"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "jmespath"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/jmespath/-/jmespath-0.15.0.tgz";
        sha1 = "a3f222a9aae9f966f5d27c796510e28091764217";
      };
    };
    "json-buffer-3.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "json-buffer";
      packageName = "json-buffer";
      version = "3.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "json-buffer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "json-buffer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/json-buffer/-/json-buffer-3.0.1.tgz";
        sha512 = "4bV5BfR2mqfQTJm+V5tPPdf+ZpuhiIvTuAB5g8kcrXOZpTT/QwwVRWBywX1ozr6lEuPdbHxwaJlm9G6mI2sfSQ==";
      };
    };
    "keyv-4.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "keyv";
      packageName = "keyv";
      version = "4.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "keyv"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "keyv"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/keyv/-/keyv-4.0.4.tgz";
        sha512 = "vqNHbAc8BBsxk+7QBYLW0Y219rWcClspR6WSeoHYKG5mnsSoOH+BL1pWq02DDCVdvvuUny5rkBlzMRzoqc+GIg==";
      };
    };
    "lodash-4.17.21" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "lodash";
      packageName = "lodash";
      version = "4.17.21";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "lodash"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "lodash"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz";
        sha512 = "v2kDEe57lecTulaDIuNTPy3Ry4gLGJ6Z1O3vE1krgXZNrsQ+LFTGHVxVjcXPs17LhbZVGedAJv8XZ1tvj5FvSg==";
      };
    };
    "lowercase-keys-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "lowercase-keys";
      packageName = "lowercase-keys";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "lowercase-keys"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "lowercase-keys"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/lowercase-keys/-/lowercase-keys-2.0.0.tgz";
        sha512 = "tqNXrS78oMOE73NMxK4EMLQsQowWf8jKooH9g7xPavRT706R6bkQJ6DY2Te7QukaZsulxa30wQ7bk0pm4XiHmA==";
      };
    };
    "lowercase-keys-3.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "lowercase-keys";
      packageName = "lowercase-keys";
      version = "3.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "lowercase-keys"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "lowercase-keys"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/lowercase-keys/-/lowercase-keys-3.0.0.tgz";
        sha512 = "ozCC6gdQ+glXOQsveKD0YsDy8DSQFjDTz4zyzEHNV5+JP5D62LmfDZ6o1cycFx9ouG940M5dE8C8CTewdj2YWQ==";
      };
    };
    "mimic-response-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "mimic-response";
      packageName = "mimic-response";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "mimic-response"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "mimic-response"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/mimic-response/-/mimic-response-1.0.1.tgz";
        sha512 = "j5EctnkH7amfV/q5Hgmoal1g2QHFJRraOtmx0JpIqkxhBhI/lJSl1nMpQ45hVarwNETOoWEimndZ4QK0RHxuxQ==";
      };
    };
    "mimic-response-3.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "mimic-response";
      packageName = "mimic-response";
      version = "3.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "mimic-response"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "mimic-response"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/mimic-response/-/mimic-response-3.1.0.tgz";
        sha512 = "z0yWI+4FDrrweS8Zmt4Ej5HdJmky15+L2e6Wgn3+iK5fWzb6T3fhNFq2+MeTRb064c6Wr4N/wv0DzQTjNzHNGQ==";
      };
    };
    "ms-2.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ms";
      packageName = "ms";
      version = "2.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ms"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ms"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/ms/-/ms-2.1.2.tgz";
        sha512 = "sGkPx+VjMtmA6MX27oA4FBFELFCZZ4S4XqeGOXCv68tT+jb3vk/RyaKWP0PTKyWtmLSM0b+adUTEvbs1PEaH2w==";
      };
    };
    "normalize-url-6.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "normalize-url";
      packageName = "normalize-url";
      version = "6.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "normalize-url"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "normalize-url"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/normalize-url/-/normalize-url-6.1.0.tgz";
        sha512 = "DlL+XwOy3NxAQ8xuC0okPgK46iuVNAK01YN7RueYBqqFeGsBjV9XmCAzAdgt+667bCl5kPh9EqKKDwnaPG1I7A==";
      };
    };
    "once-1.4.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "once";
      packageName = "once";
      version = "1.4.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "once"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "once"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/once/-/once-1.4.0.tgz";
        sha1 = "583b1aa775961d4b113ac17d9c50baef9dd76bd1";
      };
    };
    "p-cancelable-3.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "p-cancelable";
      packageName = "p-cancelable";
      version = "3.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "p-cancelable"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "p-cancelable"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/p-cancelable/-/p-cancelable-3.0.0.tgz";
        sha512 = "mlVgR3PGuzlo0MmTdk4cXqXWlwQDLnONTAg6sm62XkMJEiRxN3GL3SffkYvqwonbkJBcrI7Uvv5Zh9yjvn2iUw==";
      };
    };
    "p-timeout-5.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "p-timeout";
      packageName = "p-timeout";
      version = "5.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "p-timeout"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "p-timeout"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/p-timeout/-/p-timeout-5.0.2.tgz";
        sha512 = "sEmji9Yaq+Tw+STwsGAE56hf7gMy9p0tQfJojIAamB7WHJYJKf1qlsg9jqBWG8q9VCxKPhZaP/AcXwEoBcYQhQ==";
      };
    };
    "packet-reader-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "packet-reader";
      packageName = "packet-reader";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "packet-reader"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "packet-reader"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/packet-reader/-/packet-reader-1.0.0.tgz";
        sha512 = "HAKu/fG3HpHFO0AA8WE8q2g+gBJaZ9MG7fcKk+IJPLTGAD6Psw4443l+9DGRbOIh3/aXr7Phy0TjilYivJo5XQ==";
      };
    };
    "path-parse-1.0.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "path-parse";
      packageName = "path-parse";
      version = "1.0.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "path-parse"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "path-parse"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/path-parse/-/path-parse-1.0.7.tgz";
        sha512 = "LDJzPVEEEPR+y48z93A0Ed0yXb8pAByGWo/k5YYdYgpY2/2EsOsksJrq7lOHxryrVOn1ejG6oAp8ahvOIQD8sw==";
      };
    };
    "pg-connection-string-2.5.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "pg-connection-string";
      packageName = "pg-connection-string";
      version = "2.5.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "pg-connection-string"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "pg-connection-string"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/pg-connection-string/-/pg-connection-string-2.5.0.tgz";
        sha512 = "r5o/V/ORTA6TmUnyWZR9nCj1klXCO2CEKNRlVuJptZe85QuhFayC7WeMic7ndayT5IRIR0S0xFxFi2ousartlQ==";
      };
    };
    "pg-int8-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "pg-int8";
      packageName = "pg-int8";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "pg-int8"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "pg-int8"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/pg-int8/-/pg-int8-1.0.1.tgz";
        sha512 = "WCtabS6t3c8SkpDBUlb1kjOs7l66xsGdKpIPZsg4wR+B3+u9UAum2odSsF9tnvxg80h4ZxLWMy4pRjOsFIqQpw==";
      };
    };
    "pg-pool-3.4.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "pg-pool";
      packageName = "pg-pool";
      version = "3.4.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "pg-pool"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "pg-pool"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/pg-pool/-/pg-pool-3.4.1.tgz";
        sha512 = "TVHxR/gf3MeJRvchgNHxsYsTCHQ+4wm3VIHSS19z8NC0+gioEhq1okDY1sm/TYbfoP6JLFx01s0ShvZ3puP/iQ==";
      };
    };
    "pg-protocol-1.5.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "pg-protocol";
      packageName = "pg-protocol";
      version = "1.5.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "pg-protocol"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "pg-protocol"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/pg-protocol/-/pg-protocol-1.5.0.tgz";
        sha512 = "muRttij7H8TqRNu/DxrAJQITO4Ac7RmX3Klyr/9mJEOBeIpgnF8f9jAfRz5d3XwQZl5qBjF9gLsUtMPJE0vezQ==";
      };
    };
    "pg-types-2.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "pg-types";
      packageName = "pg-types";
      version = "2.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "pg-types"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "pg-types"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/pg-types/-/pg-types-2.2.0.tgz";
        sha512 = "qTAAlrEsl8s4OiEQY69wDvcMIdQN6wdz5ojQiOy6YRMuynxenON0O5oCpJI6lshc6scgAY8qvJ2On/p+CXY0GA==";
      };
    };
    "pgpass-1.0.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "pgpass";
      packageName = "pgpass";
      version = "1.0.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "pgpass"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "pgpass"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/pgpass/-/pgpass-1.0.5.tgz";
        sha512 = "FdW9r/jQZhSeohs1Z3sI1yxFQNFvMcnmfuj4WBMUTxOrAyLMaTcE1aAMBiTlbMNaXvBCQuVi0R7hd8udDSP7ug==";
      };
    };
    "postgres-array-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "postgres-array";
      packageName = "postgres-array";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "postgres-array"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "postgres-array"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/postgres-array/-/postgres-array-2.0.0.tgz";
        sha512 = "VpZrUqU5A69eQyW2c5CA1jtLecCsN2U/bD6VilrFDWq5+5UIEVO7nazS3TEcHf1zuPYO/sqGvUvW62g86RXZuA==";
      };
    };
    "postgres-bytea-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "postgres-bytea";
      packageName = "postgres-bytea";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "postgres-bytea"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "postgres-bytea"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/postgres-bytea/-/postgres-bytea-1.0.0.tgz";
        sha1 = "027b533c0aa890e26d172d47cf9ccecc521acd35";
      };
    };
    "postgres-date-1.0.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "postgres-date";
      packageName = "postgres-date";
      version = "1.0.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "postgres-date"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "postgres-date"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/postgres-date/-/postgres-date-1.0.7.tgz";
        sha512 = "suDmjLVQg78nMK2UZ454hAG+OAW+HQPZ6n++TNDUX+L0+uUlLywnoxJKDou51Zm+zTCjrCl0Nq6J9C5hP9vK/Q==";
      };
    };
    "postgres-interval-1.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "postgres-interval";
      packageName = "postgres-interval";
      version = "1.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "postgres-interval"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "postgres-interval"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/postgres-interval/-/postgres-interval-1.2.0.tgz";
        sha512 = "9ZhXKM/rw350N1ovuWHbGxnGh/SNJ4cnxHiM0rxE4VN41wsg8P8zWn9hv/buK00RP4WvlOyr/RBDiptyxVbkZQ==";
      };
    };
    "pump-3.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "pump";
      packageName = "pump";
      version = "3.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "pump"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "pump"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/pump/-/pump-3.0.0.tgz";
        sha512 = "LwZy+p3SFs1Pytd/jYct4wpv49HiYCqd9Rlc5ZVdk0V+8Yzv6jR5Blk3TRmPL1ft69TxP0IMZGJ+WPFU2BFhww==";
      };
    };
    "punycode-1.3.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "punycode";
      packageName = "punycode";
      version = "1.3.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "punycode"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "punycode"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/punycode/-/punycode-1.3.2.tgz";
        sha1 = "9653a036fb7c1ee42342f2325cceefea3926c48d";
      };
    };
    "querystring-0.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "querystring";
      packageName = "querystring";
      version = "0.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "querystring"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "querystring"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/querystring/-/querystring-0.2.0.tgz";
        sha1 = "b209849203bb25df820da756e747005878521620";
      };
    };
    "quick-lru-5.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "quick-lru";
      packageName = "quick-lru";
      version = "5.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "quick-lru"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "quick-lru"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/quick-lru/-/quick-lru-5.1.1.tgz";
        sha512 = "WuyALRjWPDGtt/wzJiadO5AXY+8hZ80hVpe6MyivgraREW751X3SbhRvG3eLKOYN+8VEvqLcf3wdnt44Z4S4SA==";
      };
    };
    "rechoir-0.7.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "rechoir";
      packageName = "rechoir";
      version = "0.7.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "rechoir"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "rechoir"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/rechoir/-/rechoir-0.7.0.tgz";
        sha512 = "ADsDEH2bvbjltXEP+hTIAmeFekTFK0V2BTxMkok6qILyAJEXV0AFfoWcAq4yfll5VdIMd/RVXq0lR+wQi5ZU3Q==";
      };
    };
    "resolve-1.20.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "resolve";
      packageName = "resolve";
      version = "1.20.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "resolve"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "resolve"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/resolve/-/resolve-1.20.0.tgz";
        sha512 = "wENBPt4ySzg4ybFQW2TT1zMQucPK95HSh/nq2CFTZVOGut2+pQvSsgtda4d26YrYcr067wjbmzOG8byDPBX63A==";
      };
    };
    "resolve-alpn-1.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "resolve-alpn";
      packageName = "resolve-alpn";
      version = "1.2.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "resolve-alpn"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "resolve-alpn"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/resolve-alpn/-/resolve-alpn-1.2.1.tgz";
        sha512 = "0a1F4l73/ZFZOakJnQ3FvkJ2+gSTQWz/r2KE5OdDY0TxPm5h4GkqkWWfM47T7HsbnOtcJVEF4epCVy6u7Q3K+g==";
      };
    };
    "resolve-from-5.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "resolve-from";
      packageName = "resolve-from";
      version = "5.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "resolve-from"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "resolve-from"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/resolve-from/-/resolve-from-5.0.0.tgz";
        sha512 = "qYg9KP24dD5qka9J47d0aVky0N+b4fTU89LN9iDnjB5waksiC49rvMB0PrUJQGoTmH50XPiqOvAjDfaijGxYZw==";
      };
    };
    "responselike-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "responselike";
      packageName = "responselike";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "responselike"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "responselike"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/responselike/-/responselike-2.0.0.tgz";
        sha512 = "xH48u3FTB9VsZw7R+vvgaKeLKzT6jOogbQhEe/jewwnZgzPcnyWui2Av6JpoYZF/91uueC+lqhWqeURw5/qhCw==";
      };
    };
    "retry-0.13.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "retry";
      packageName = "retry";
      version = "0.13.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "retry"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "retry"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/retry/-/retry-0.13.1.tgz";
        sha512 = "XQBQ3I8W1Cge0Seh+6gjj03LbmRFWuoszgK9ooCpwYIrhhoO80pfq4cUkU5DkknwfOfFteRwlZ56PYOGYyFWdg==";
      };
    };
    "sax-1.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "sax";
      packageName = "sax";
      version = "1.2.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "sax"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "sax"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/sax/-/sax-1.2.1.tgz";
        sha1 = "7b8e656190b228e81a66aea748480d828cd2d37a";
      };
    };
    "split2-4.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "split2";
      packageName = "split2";
      version = "4.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "split2"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "split2"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/split2/-/split2-4.1.0.tgz";
        sha512 = "VBiJxFkxiXRlUIeyMQi8s4hgvKCSjtknJv/LVYbrgALPwf5zSKmEwV9Lst25AkvMDnvxODugjdl6KZgwKM1WYQ==";
      };
    };
    "tarn-3.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "tarn";
      packageName = "tarn";
      version = "3.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "tarn"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "tarn"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/tarn/-/tarn-3.0.2.tgz";
        sha512 = "51LAVKUSZSVfI05vjPESNc5vwqqZpbXCsU+/+wxlOrUjk2SnFTt97v9ZgQrD4YmxYW1Px6w2KjaDitCfkvgxMQ==";
      };
    };
    "tildify-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "tildify";
      packageName = "tildify";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "tildify"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "tildify"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/tildify/-/tildify-2.0.0.tgz";
        sha512 = "Cc+OraorugtXNfs50hU9KS369rFXCfgGLpfCfvlc+Ud5u6VWmUQsOAa9HbTvheQdYnrdJqqv1e5oIqXppMYnSw==";
      };
    };
    "url-0.10.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "url";
      packageName = "url";
      version = "0.10.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "url"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "url"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/url/-/url-0.10.3.tgz";
        sha1 = "021e4d9c7705f21bbf37d03ceb58767402774c64";
      };
    };
    "uuid-3.3.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "uuid";
      packageName = "uuid";
      version = "3.3.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "uuid"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "uuid"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/uuid/-/uuid-3.3.2.tgz";
        sha512 = "yXJmeNaw3DnnKAOKJE51sL/ZaYfWJRl1pK9dr19YFCu0ObS231AB1/LbqTKRAQ5kw8A90rA6fr4riOUpTZvQZA==";
      };
    };
    "wrappy-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "wrappy";
      packageName = "wrappy";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "wrappy"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "wrappy"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/wrappy/-/wrappy-1.0.2.tgz";
        sha1 = "b5243d8f3ec1aa35f1364605bc0d1036e30ab69f";
      };
    };
    "xml2js-0.4.19" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "xml2js";
      packageName = "xml2js";
      version = "0.4.19";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "xml2js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "xml2js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/xml2js/-/xml2js-0.4.19.tgz";
        sha512 = "esZnJZJOiJR9wWKMyuvSE1y6Dq5LCuJanqhxslH2bxM6duahNZ+HMpCLhBQGZkbX6xRf8x1Y2eJlgt2q3qo49Q==";
      };
    };
    "xmlbuilder-9.0.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "xmlbuilder";
      packageName = "xmlbuilder";
      version = "9.0.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "xmlbuilder"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "xmlbuilder"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/xmlbuilder/-/xmlbuilder-9.0.7.tgz";
        sha1 = "132ee63d2ec5565c557e20f4c22df9aca686b10d";
      };
    };
    "xtend-4.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "xtend";
      packageName = "xtend";
      version = "4.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "xtend"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "xtend"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/xtend/-/xtend-4.0.2.tgz";
        sha512 = "LKYU1iAXJXUgAXn9URjiu+MWhyUXHsvfp7mcuYm9dSUKK0/CjtrUwFAxD82/mCWbtLsGjFIad0wIsod4zrTAEQ==";
      };
    };
    "yocto-queue-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "yocto-queue";
      packageName = "yocto-queue";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "yocto-queue"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "yocto-queue"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/yocto-queue/-/yocto-queue-1.0.0.tgz";
        sha512 = "9bnSc/HEW2uRy67wc+T8UwauLuPJVn28jb+GtJY16iiKWyvmYJRXVT4UamsAEGQfPohgr2q4Tq0sQbQlxTfi1g==";
      };
    };
    "yoctodelay-1.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "yoctodelay";
      packageName = "yoctodelay";
      version = "1.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "yoctodelay"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "yoctodelay"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/yoctodelay/-/yoctodelay-1.2.0.tgz";
        sha512 = "12y/P9MSig9/5BEhBgylss+fkHiCRZCvYR81eH35NW9uw801cvJt31EAV+WOLcwZRZbLiIQl/hxcdXXXFmGvXg==";
      };
    };
  };
  jsnixDeps = {
    async-retry = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "async-retry"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "async-retry";
      packageName = "async-retry";
      version = "1.3.3";
      src = fetchurl {
        url = "https://registry.npmjs.org/async-retry/-/async-retry-1.3.3.tgz";
        sha512 = "wfr/jstw9xNi/0teMHrRW7dsz3Lt5ARhYNZ2ewpadnhaIp5mbALhOAP+EAdsC7t4Z6wqsDVv9+W6gm1Dk9mEyw==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "async-retry"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "async-retry"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "async-retry"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "async-retry"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "async-retry"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "async-retry"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "async-retry"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "async-retry"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "async-retry"; });
      meta = {
        description = "Retrying made simple, easy and async";
        license = "MIT";
        homepage = "https://github.com/vercel/async-retry#readme";
      };
    };
    aws-sdk = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "aws-sdk"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "aws-sdk";
      packageName = "aws-sdk";
      version = "2.1047.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/aws-sdk/-/aws-sdk-2.1047.0.tgz";
        sha512 = "aZg6HzcwgRpXLi8HnpwBwK+NTXlWPjLSChvdeJ+/IE9912aoAKyaV+Ydo+9h6XH0cQhkvZ2u3pFINWZVbwo+TA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "aws-sdk"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "aws-sdk"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "aws-sdk"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "aws-sdk"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "aws-sdk"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "aws-sdk"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "aws-sdk"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "aws-sdk"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "aws-sdk"; });
      meta = {
        description = "AWS SDK for JavaScript";
        license = "Apache-2.0";
        homepage = "https://github.com/aws/aws-sdk-js";
      };
    };
    dotenv = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "dotenv"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "dotenv";
      packageName = "dotenv";
      version = "10.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/dotenv/-/dotenv-10.0.0.tgz";
        sha512 = "rlBi9d8jpv9Sf1klPjNfFAuWDjKLwTIJJ/VxtoTwIR6hnZxcEOQCZg2oIL3MWBYw5GpUDKOEnND7LXTbIpQ03Q==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "dotenv"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "dotenv"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "dotenv"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "dotenv"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "dotenv"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "dotenv"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "dotenv"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "dotenv"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "dotenv"; });
      meta = {
        description = "Loads environment variables from .env file";
        license = "BSD-2-Clause";
        homepage = "https://github.com/motdotla/dotenv#readme";
      };
    };
    exit-hook = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "exit-hook"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "exit-hook";
      packageName = "exit-hook";
      version = "3.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/exit-hook/-/exit-hook-3.0.0.tgz";
        sha512 = "ElRvnoj3dvOc5WjnQx0CF66rS0xehV6eZdcmqZX17uOLPy3me43frl8UD73Frkx5Aq5kgziMDECjDJR2X1oBFQ==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "exit-hook"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "exit-hook"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "exit-hook"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "exit-hook"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "exit-hook"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "exit-hook"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "exit-hook"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "exit-hook"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "exit-hook"; });
      meta = {
        description = "Run some code when the process exits";
        license = "MIT";
        homepage = "https://github.com/sindresorhus/exit-hook#readme";
      };
    };
    got = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "got"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "got";
      packageName = "got";
      version = "12.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/got/-/got-12.0.0.tgz";
        sha512 = "gNNNghQ1yw0hyzie1FLK6gY90BQlXU9zSByyRygnbomHPruKQ6hAKKbpO1RfNZp8b+qNzNipGeRG3tUelKcVsA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "got"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "got"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "got"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "got"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "got"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "got"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "got"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "got"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "got"; });
      meta = {
        description = "Human-friendly and powerful HTTP request library for Node.js";
        license = "MIT";
        homepage = "https://github.com/sindresorhus/got#readme";
      };
    };
    knex = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "knex"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "knex";
      packageName = "knex";
      version = "0.95.15";
      src = fetchurl {
        url = "https://registry.npmjs.org/knex/-/knex-0.95.15.tgz";
        sha512 = "Loq6WgHaWlmL2bfZGWPsy4l8xw4pOE+tmLGkPG0auBppxpI0UcK+GYCycJcqz9W54f2LiGewkCVLBm3Wq4ur/w==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "knex"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "knex"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "knex"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "knex"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "knex"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "knex"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "knex"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "knex"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "knex"; });
      meta = {
        description = "A batteries-included SQL query & schema builder for PostgresSQL, MySQL, CockroachDB, MSSQL and SQLite3";
        license = "MIT";
        homepage = "https://knexjs.org";
      };
    };
    moment = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "moment"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "moment";
      packageName = "moment";
      version = "2.29.1";
      src = fetchurl {
        url = "https://registry.npmjs.org/moment/-/moment-2.29.1.tgz";
        sha512 = "kHmoybcPV8Sqy59DwNDY3Jefr64lK/by/da0ViFcuA4DH0vQg5Q6Ze5VimxkfQNSC+Mls/Kx53s7TjP1RhFEDQ==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "moment"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "moment"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "moment"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "moment"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "moment"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "moment"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "moment"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "moment"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "moment"; });
      meta = {
        description = "Parse, validate, manipulate, and display dates";
        license = "MIT";
        homepage = "https://momentjs.com";
      };
    };
    p-limit = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "p-limit"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "p-limit";
      packageName = "p-limit";
      version = "4.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/p-limit/-/p-limit-4.0.0.tgz";
        sha512 = "5b0R4txpzjPWVw/cXXUResoD4hb6U/x9BH08L7nw+GN1sezDzPdxeRvpc9c433fZhBan/wusjbCsqwqm4EIBIQ==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "p-limit"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "p-limit"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "p-limit"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "p-limit"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "p-limit"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "p-limit"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "p-limit"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "p-limit"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "p-limit"; });
      meta = {
        description = "Run multiple promise-returning & async functions with limited concurrency";
        license = "MIT";
        homepage = "https://github.com/sindresorhus/p-limit#readme";
      };
    };
    p-min-delay = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "p-min-delay"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "p-min-delay";
      packageName = "p-min-delay";
      version = "4.0.1";
      src = fetchurl {
        url = "https://registry.npmjs.org/p-min-delay/-/p-min-delay-4.0.1.tgz";
        sha512 = "Tgkn+fy2VYNWw9bLy4BwiF+1ZMIgTDBIpaIChi1HC3N4nwRpandJnG1jAEXiYCcrTZKYQJdBWzLJauAeYDXsBg==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "p-min-delay"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "p-min-delay"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "p-min-delay"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "p-min-delay"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "p-min-delay"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "p-min-delay"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "p-min-delay"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "p-min-delay"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "p-min-delay"; });
      meta = {
        description = "Delay a promise a minimum amount of time";
        license = "MIT";
        homepage = "https://github.com/sindresorhus/p-min-delay#readme";
      };
    };
    p-wait-for = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "p-wait-for"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "p-wait-for";
      packageName = "p-wait-for";
      version = "4.1.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/p-wait-for/-/p-wait-for-4.1.0.tgz";
        sha512 = "i8nE5q++9h8oaQHWltS1Tnnv4IoMDOlqN7C0KFG2OdbK0iFJIt6CROZ8wfBM+K4Pxqfnq4C4lkkpXqTEpB5DZw==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "p-wait-for"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "p-wait-for"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "p-wait-for"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "p-wait-for"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "p-wait-for"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "p-wait-for"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "p-wait-for"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "p-wait-for"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "p-wait-for"; });
      meta = {
        description = "Wait for a condition to be true";
        license = "MIT";
        homepage = "https://github.com/sindresorhus/p-wait-for#readme";
      };
    };
    p-whilst = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "p-whilst"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "p-whilst";
      packageName = "p-whilst";
      version = "3.0.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/p-whilst/-/p-whilst-3.0.0.tgz";
        sha512 = "vaiNNmeIUGtMzf121RTb3CCC0Nl4WNeHjbmPjRcwPo6vQiHEJRpHbeOcyLBZspuyz2yG+G2xwzVIiULd1Mk6MA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "p-whilst"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "p-whilst"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "p-whilst"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "p-whilst"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "p-whilst"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "p-whilst"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "p-whilst"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "p-whilst"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "p-whilst"; });
      meta = {
        description = "While a condition returns true, calls a function repeatedly, and then resolves the promise";
        license = "MIT";
        homepage = "https://github.com/sindresorhus/p-whilst#readme";
      };
    };
    pg = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "pg"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "pg";
      packageName = "pg";
      version = "8.7.1";
      src = fetchurl {
        url = "https://registry.npmjs.org/pg/-/pg-8.7.1.tgz";
        sha512 = "7bdYcv7V6U3KAtWjpQJJBww0UEsWuh4yQ/EjNf2HeO/NnvKjpvhEIe/A/TleP6wtmSKnUnghs5A9jUoK6iDdkA==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "pg"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "pg"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "pg"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "pg"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "pg"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "pg"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "pg"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "pg"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "pg"; });
      meta = {
        description = "PostgreSQL client - pure javascript & libpq with the same API";
        license = "MIT";
        homepage = "https://github.com/brianc/node-postgres";
      };
    };
    ramda = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "ramda"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "ramda";
      packageName = "ramda";
      version = "0.27.1";
      src = fetchurl {
        url = "https://registry.npmjs.org/ramda/-/ramda-0.27.1.tgz";
        sha512 = "PgIdVpn5y5Yns8vqb8FzBUEYn98V3xcPgawAkkgj0YJ0qDsnHCiNmZYfOGMgOvoB0eWFLpYbhxUR3mxfDIMvpw==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "ramda"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "ramda"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "ramda"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "ramda"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "ramda"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "ramda"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "ramda"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "ramda"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "ramda"; });
      meta = {
        description = "A practical functional library for JavaScript programmers.";
        license = "MIT";
        homepage = "https://ramdajs.com/";
      };
    };
    sqs-consumer = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "sqs-consumer"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "sqs-consumer";
      packageName = "sqs-consumer";
      version = "5.6.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/sqs-consumer/-/sqs-consumer-5.6.0.tgz";
        sha512 = "p+K3UV8GwF1//Nfq7swbm/Un137IwxewzxapfTyyEVpdmzPKEDYrAzuGJvP87YWVSWzbkvxQ0By0vhamouGdxg==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "sqs-consumer"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "sqs-consumer"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "sqs-consumer"; };
      buildPhase = ''
      source $unpackScriptPath 
      runHook preBuild
      if [ -z "$preBuild" ]; then
        runHook preInstall
      fi
      source $buildScriptPath
      if [ -z "$postBuild" ]; then
        runHook postBuild
      fi
    '';
      patchPhase = ''
      if [ -z "$prePatch" ]; then
        runHook prePatch
      fi
      
      if [ -z "$postPatch" ]; then
        runHook postPatch
      fi
    '';
      installScript = mkInstallScript { pkgName = "sqs-consumer"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "sqs-consumer"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "sqs-consumer"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "sqs-consumer"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "sqs-consumer"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "sqs-consumer"; });
      meta = {
        description = "Build SQS-based Node applications without the boilerplate";
        license = "Apache-2.0";
        homepage = "https://github.com/BBC/sqs-consumer";
      };
    };
  };
  dedupedDeps = {
    retry = sources."retry-0.13.1" {
      dependencies = [];
    };
    base64-js = sources."base64-js-1.5.1" {
      dependencies = [];
    };
    buffer = sources."buffer-4.9.2" {
      dependencies = [];
    };
    events = sources."events-1.1.1" {
      dependencies = [];
    };
    ieee754 = sources."ieee754-1.1.13" {
      dependencies = [];
    };
    isarray = sources."isarray-1.0.0" {
      dependencies = [];
    };
    jmespath = sources."jmespath-0.15.0" {
      dependencies = [];
    };
    punycode = sources."punycode-1.3.2" {
      dependencies = [];
    };
    querystring = sources."querystring-0.2.0" {
      dependencies = [];
    };
    sax = sources."sax-1.2.1" {
      dependencies = [];
    };
    url = sources."url-0.10.3" {
      dependencies = [];
    };
    uuid = sources."uuid-3.3.2" {
      dependencies = [];
    };
    xml2js = sources."xml2js-0.4.19" {
      dependencies = [];
    };
    xmlbuilder = sources."xmlbuilder-9.0.7" {
      dependencies = [];
    };
    "@sindresorhus/is" = sources."@sindresorhus/is-4.2.0" {
      dependencies = [];
    };
    "@szmarczak/http-timer" = sources."@szmarczak/http-timer-5.0.1" {
      dependencies = [];
    };
    "@types/cacheable-request" = sources."@types/cacheable-request-6.0.2" {
      dependencies = [];
    };
    "@types/http-cache-semantics" = sources."@types/http-cache-semantics-4.0.1" {
      dependencies = [];
    };
    "@types/keyv" = sources."@types/keyv-3.1.3" {
      dependencies = [];
    };
    "@types/node" = sources."@types/node-17.0.2" {
      dependencies = [];
    };
    "@types/responselike" = sources."@types/responselike-1.0.0" {
      dependencies = [];
    };
    cacheable-lookup = sources."cacheable-lookup-6.0.4" {
      dependencies = [];
    };
    cacheable-request = sources."cacheable-request-7.0.2" {
      dependencies = [
        (sources."get-stream-5.2.0" {
          dependencies = [];
        })
        (sources."lowercase-keys-2.0.0" {
          dependencies = [];
        })
      ];
    };
    clone-response = sources."clone-response-1.0.2" {
      dependencies = [];
    };
    decompress-response = sources."decompress-response-6.0.0" {
      dependencies = [
        (sources."mimic-response-3.1.0" {
          dependencies = [];
        })
      ];
    };
    defer-to-connect = sources."defer-to-connect-2.0.1" {
      dependencies = [];
    };
    end-of-stream = sources."end-of-stream-1.4.4" {
      dependencies = [];
    };
    form-data-encoder = sources."form-data-encoder-1.7.1" {
      dependencies = [];
    };
    get-stream = sources."get-stream-6.0.1" {
      dependencies = [];
    };
    http-cache-semantics = sources."http-cache-semantics-4.1.0" {
      dependencies = [];
    };
    http2-wrapper = sources."http2-wrapper-2.1.10" {
      dependencies = [];
    };
    json-buffer = sources."json-buffer-3.0.1" {
      dependencies = [];
    };
    keyv = sources."keyv-4.0.4" {
      dependencies = [];
    };
    lowercase-keys = sources."lowercase-keys-3.0.0" {
      dependencies = [];
    };
    mimic-response = sources."mimic-response-1.0.1" {
      dependencies = [];
    };
    normalize-url = sources."normalize-url-6.1.0" {
      dependencies = [];
    };
    once = sources."once-1.4.0" {
      dependencies = [];
    };
    p-cancelable = sources."p-cancelable-3.0.0" {
      dependencies = [];
    };
    pump = sources."pump-3.0.0" {
      dependencies = [];
    };
    quick-lru = sources."quick-lru-5.1.1" {
      dependencies = [];
    };
    resolve-alpn = sources."resolve-alpn-1.2.1" {
      dependencies = [];
    };
    responselike = sources."responselike-2.0.0" {
      dependencies = [
        (sources."lowercase-keys-2.0.0" {
          dependencies = [];
        })
      ];
    };
    wrappy = sources."wrappy-1.0.2" {
      dependencies = [];
    };
    colorette = sources."colorette-2.0.16" {
      dependencies = [];
    };
    commander = sources."commander-7.2.0" {
      dependencies = [];
    };
    debug = sources."debug-4.3.2" {
      dependencies = [];
    };
    escalade = sources."escalade-3.1.1" {
      dependencies = [];
    };
    esm = sources."esm-3.2.25" {
      dependencies = [];
    };
    function-bind = sources."function-bind-1.1.1" {
      dependencies = [];
    };
    getopts = sources."getopts-2.2.5" {
      dependencies = [];
    };
    has = sources."has-1.0.3" {
      dependencies = [];
    };
    interpret = sources."interpret-2.2.0" {
      dependencies = [];
    };
    is-core-module = sources."is-core-module-2.8.0" {
      dependencies = [];
    };
    lodash = sources."lodash-4.17.21" {
      dependencies = [];
    };
    ms = sources."ms-2.1.2" {
      dependencies = [];
    };
    path-parse = sources."path-parse-1.0.7" {
      dependencies = [];
    };
    pg-connection-string = sources."pg-connection-string-2.5.0" {
      dependencies = [];
    };
    rechoir = sources."rechoir-0.7.0" {
      dependencies = [];
    };
    resolve = sources."resolve-1.20.0" {
      dependencies = [];
    };
    resolve-from = sources."resolve-from-5.0.0" {
      dependencies = [];
    };
    tarn = sources."tarn-3.0.2" {
      dependencies = [];
    };
    tildify = sources."tildify-2.0.0" {
      dependencies = [];
    };
    yocto-queue = sources."yocto-queue-1.0.0" {
      dependencies = [];
    };
    yoctodelay = sources."yoctodelay-1.2.0" {
      dependencies = [];
    };
    p-timeout = sources."p-timeout-5.0.2" {
      dependencies = [];
    };
    buffer-writer = sources."buffer-writer-2.0.0" {
      dependencies = [];
    };
    packet-reader = sources."packet-reader-1.0.0" {
      dependencies = [];
    };
    pg-int8 = sources."pg-int8-1.0.1" {
      dependencies = [];
    };
    pg-pool = sources."pg-pool-3.4.1" {
      dependencies = [];
    };
    pg-protocol = sources."pg-protocol-1.5.0" {
      dependencies = [];
    };
    pg-types = sources."pg-types-2.2.0" {
      dependencies = [];
    };
    pgpass = sources."pgpass-1.0.5" {
      dependencies = [];
    };
    postgres-array = sources."postgres-array-2.0.0" {
      dependencies = [];
    };
    postgres-bytea = sources."postgres-bytea-1.0.0" {
      dependencies = [];
    };
    postgres-date = sources."postgres-date-1.0.7" {
      dependencies = [];
    };
    postgres-interval = sources."postgres-interval-1.2.0" {
      dependencies = [];
    };
    split2 = sources."split2-4.1.0" {
      dependencies = [];
    };
    xtend = sources."xtend-4.0.2" {
      dependencies = [];
    };
  };
  isolateDeps = {};
in
jsnixDeps // (if builtins.hasAttr "packageDerivation" packageNix then {
  "${packageNix.name}" = jsnixDrvOverrides {
    inherit dedupedDeps jsnixDeps isolateDeps;
    drv_ = packageNix.packageDerivation;
  };
} else {})