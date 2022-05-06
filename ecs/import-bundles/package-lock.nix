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
    "@babel/runtime-7.17.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_babel_slash_runtime";
      packageName = "@babel/runtime";
      version = "7.17.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@babel/runtime"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@babel/runtime"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@babel/runtime/-/runtime-7.17.2.tgz";
        sha512 = "hzeyJyMA1YGdJTuWU0e/j4wKXrU4OMFvY2MSlaI9B7VQb0r5cxTE3EAIS2Q7Tn2RIcDkRvTA/v2JsAEhxe99uw==";
      };
    };
    "@colors/colors-1.5.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_colors_slash_colors";
      packageName = "@colors/colors";
      version = "1.5.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@colors/colors"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@colors/colors"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@colors/colors/-/colors-1.5.0.tgz";
        sha512 = "ooWCrlZP11i8GImSjTHYHLkvFDP48nS4+204nGb1RiX/WXYHmJA2III9/e2DWVabCESdW7hBAEzHRqUn9OUVvQ==";
      };
    };
    "@cspotcode/source-map-consumer-0.8.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_cspotcode_slash_source-map-consumer";
      packageName = "@cspotcode/source-map-consumer";
      version = "0.8.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@cspotcode/source-map-consumer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@cspotcode/source-map-consumer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@cspotcode/source-map-consumer/-/source-map-consumer-0.8.0.tgz";
        sha512 = "41qniHzTU8yAGbCp04ohlmSrZf8bkf/iJsl3V0dRGsQN/5GFfx+LbCSsCpp2gqrqjTVg/K6O8ycoV35JIwAzAg==";
      };
    };
    "@cspotcode/source-map-support-0.7.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_cspotcode_slash_source-map-support";
      packageName = "@cspotcode/source-map-support";
      version = "0.7.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@cspotcode/source-map-support"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@cspotcode/source-map-support"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@cspotcode/source-map-support/-/source-map-support-0.7.0.tgz";
        sha512 = "X4xqRHqN8ACt2aHVe51OxeA2HjbcL4MqFqXkrmQszJ1NOUuUu5u6Vqx/0lZSVNku7velL5FC/s5uEAj1lsBMhA==";
      };
    };
    "@dabh/diagnostics-2.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_dabh_slash_diagnostics";
      packageName = "@dabh/diagnostics";
      version = "2.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@dabh/diagnostics"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@dabh/diagnostics"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@dabh/diagnostics/-/diagnostics-2.0.3.tgz";
        sha512 = "hrlQOIi7hAfzsMqlGSFyVucrx38O+j6wiGOf//H2ecvIEqYN4ADBSS2iLMh5UFyDunCNniUIPk/q3riFv45xRA==";
      };
    };
    "@ethersproject/abi-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_abi";
      packageName = "@ethersproject/abi";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/abi"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/abi"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/abi/-/abi-5.6.0.tgz";
        sha512 = "AhVByTwdXCc2YQ20v300w6KVHle9g2OFc28ZAFCPnJyEpkv1xKXjZcSTgWOlv1i+0dqlgF8RCF2Rn2KC1t+1Vg==";
      };
    };
    "@ethersproject/abstract-provider-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_abstract-provider";
      packageName = "@ethersproject/abstract-provider";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/abstract-provider"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/abstract-provider"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/abstract-provider/-/abstract-provider-5.6.0.tgz";
        sha512 = "oPMFlKLN+g+y7a79cLK3WiLcjWFnZQtXWgnLAbHZcN3s7L4v90UHpTOrLk+m3yr0gt+/h9STTM6zrr7PM8uoRw==";
      };
    };
    "@ethersproject/abstract-signer-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_abstract-signer";
      packageName = "@ethersproject/abstract-signer";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/abstract-signer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/abstract-signer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/abstract-signer/-/abstract-signer-5.6.0.tgz";
        sha512 = "WOqnG0NJKtI8n0wWZPReHtaLkDByPL67tn4nBaDAhmVq8sjHTPbCdz4DRhVu/cfTOvfy9w3iq5QZ7BX7zw56BQ==";
      };
    };
    "@ethersproject/address-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_address";
      packageName = "@ethersproject/address";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/address"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/address"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/address/-/address-5.6.0.tgz";
        sha512 = "6nvhYXjbXsHPS+30sHZ+U4VMagFC/9zAk6Gd/h3S21YW4+yfb0WfRtaAIZ4kfM4rrVwqiy284LP0GtL5HXGLxQ==";
      };
    };
    "@ethersproject/base64-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_base64";
      packageName = "@ethersproject/base64";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/base64"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/base64"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/base64/-/base64-5.6.0.tgz";
        sha512 = "2Neq8wxJ9xHxCF9TUgmKeSh9BXJ6OAxWfeGWvbauPh8FuHEjamgHilllx8KkSd5ErxyHIX7Xv3Fkcud2kY9ezw==";
      };
    };
    "@ethersproject/basex-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_basex";
      packageName = "@ethersproject/basex";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/basex"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/basex"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/basex/-/basex-5.6.0.tgz";
        sha512 = "qN4T+hQd/Md32MoJpc69rOwLYRUXwjTlhHDIeUkUmiN/JyWkkLLMoG0TqvSQKNqZOMgN5stbUYN6ILC+eD7MEQ==";
      };
    };
    "@ethersproject/bignumber-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_bignumber";
      packageName = "@ethersproject/bignumber";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/bignumber"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/bignumber"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/bignumber/-/bignumber-5.6.0.tgz";
        sha512 = "VziMaXIUHQlHJmkv1dlcd6GY2PmT0khtAqaMctCIDogxkrarMzA9L94KN1NeXqqOfFD6r0sJT3vCTOFSmZ07DA==";
      };
    };
    "@ethersproject/bytes-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_bytes";
      packageName = "@ethersproject/bytes";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/bytes"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/bytes"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/bytes/-/bytes-5.6.0.tgz";
        sha512 = "3hJPlYemb9V4VLfJF5BfN0+55vltPZSHU3QKUyP9M3Y2TcajbiRrz65UG+xVHOzBereB1b9mn7r12o177xgN7w==";
      };
    };
    "@ethersproject/constants-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_constants";
      packageName = "@ethersproject/constants";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/constants"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/constants"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/constants/-/constants-5.6.0.tgz";
        sha512 = "SrdaJx2bK0WQl23nSpV/b1aq293Lh0sUaZT/yYKPDKn4tlAbkH96SPJwIhwSwTsoQQZxuh1jnqsKwyymoiBdWA==";
      };
    };
    "@ethersproject/contracts-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_contracts";
      packageName = "@ethersproject/contracts";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/contracts"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/contracts"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/contracts/-/contracts-5.6.0.tgz";
        sha512 = "74Ge7iqTDom0NX+mux8KbRUeJgu1eHZ3iv6utv++sLJG80FVuU9HnHeKVPfjd9s3woFhaFoQGf3B3iH/FrQmgw==";
      };
    };
    "@ethersproject/hash-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_hash";
      packageName = "@ethersproject/hash";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/hash"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/hash"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/hash/-/hash-5.6.0.tgz";
        sha512 = "fFd+k9gtczqlr0/BruWLAu7UAOas1uRRJvOR84uDf4lNZ+bTkGl366qvniUZHKtlqxBRU65MkOobkmvmpHU+jA==";
      };
    };
    "@ethersproject/hdnode-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_hdnode";
      packageName = "@ethersproject/hdnode";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/hdnode"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/hdnode"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/hdnode/-/hdnode-5.6.0.tgz";
        sha512 = "61g3Jp3nwDqJcL/p4nugSyLrpl/+ChXIOtCEM8UDmWeB3JCAt5FoLdOMXQc3WWkc0oM2C0aAn6GFqqMcS/mHTw==";
      };
    };
    "@ethersproject/json-wallets-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_json-wallets";
      packageName = "@ethersproject/json-wallets";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/json-wallets"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/json-wallets"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/json-wallets/-/json-wallets-5.6.0.tgz";
        sha512 = "fmh86jViB9r0ibWXTQipxpAGMiuxoqUf78oqJDlCAJXgnJF024hOOX7qVgqsjtbeoxmcLwpPsXNU0WEe/16qPQ==";
      };
    };
    "@ethersproject/keccak256-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_keccak256";
      packageName = "@ethersproject/keccak256";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/keccak256"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/keccak256"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/keccak256/-/keccak256-5.6.0.tgz";
        sha512 = "tk56BJ96mdj/ksi7HWZVWGjCq0WVl/QvfhFQNeL8fxhBlGoP+L80uDCiQcpJPd+2XxkivS3lwRm3E0CXTfol0w==";
      };
    };
    "@ethersproject/logger-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_logger";
      packageName = "@ethersproject/logger";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/logger"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/logger"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/logger/-/logger-5.6.0.tgz";
        sha512 = "BiBWllUROH9w+P21RzoxJKzqoqpkyM1pRnEKG69bulE9TSQD8SAIvTQqIMZmmCO8pUNkgLP1wndX1gKghSpBmg==";
      };
    };
    "@ethersproject/networks-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_networks";
      packageName = "@ethersproject/networks";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/networks"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/networks"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/networks/-/networks-5.6.0.tgz";
        sha512 = "DaVzgyThzHgSDLuURhvkp4oviGoGe9iTZW4jMEORHDRCgSZ9K9THGFKqL+qGXqPAYLEgZTf5z2w56mRrPR1MjQ==";
      };
    };
    "@ethersproject/pbkdf2-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_pbkdf2";
      packageName = "@ethersproject/pbkdf2";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/pbkdf2"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/pbkdf2"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/pbkdf2/-/pbkdf2-5.6.0.tgz";
        sha512 = "Wu1AxTgJo3T3H6MIu/eejLFok9TYoSdgwRr5oGY1LTLfmGesDoSx05pemsbrPT2gG4cQME+baTSCp5sEo2erZQ==";
      };
    };
    "@ethersproject/properties-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_properties";
      packageName = "@ethersproject/properties";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/properties"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/properties"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/properties/-/properties-5.6.0.tgz";
        sha512 = "szoOkHskajKePTJSZ46uHUWWkbv7TzP2ypdEK6jGMqJaEt2sb0jCgfBo0gH0m2HBpRixMuJ6TBRaQCF7a9DoCg==";
      };
    };
    "@ethersproject/providers-5.6.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_providers";
      packageName = "@ethersproject/providers";
      version = "5.6.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/providers"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/providers"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/providers/-/providers-5.6.1.tgz";
        sha512 = "w8Wx15nH+aVDvnoKCyI1f3x0B5idmk/bDJXMEUqCfdO8Eadd0QpDx9lDMTMmenhOmf9vufLJXjpSm24D3ZnVpg==";
      };
    };
    "@ethersproject/random-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_random";
      packageName = "@ethersproject/random";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/random"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/random"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/random/-/random-5.6.0.tgz";
        sha512 = "si0PLcLjq+NG/XHSZz90asNf+YfKEqJGVdxoEkSukzbnBgC8rydbgbUgBbBGLeHN4kAJwUFEKsu3sCXT93YMsw==";
      };
    };
    "@ethersproject/rlp-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_rlp";
      packageName = "@ethersproject/rlp";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/rlp"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/rlp"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/rlp/-/rlp-5.6.0.tgz";
        sha512 = "dz9WR1xpcTL+9DtOT/aDO+YyxSSdO8YIS0jyZwHHSlAmnxA6cKU3TrTd4Xc/bHayctxTgGLYNuVVoiXE4tTq1g==";
      };
    };
    "@ethersproject/sha2-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_sha2";
      packageName = "@ethersproject/sha2";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/sha2"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/sha2"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/sha2/-/sha2-5.6.0.tgz";
        sha512 = "1tNWCPFLu1n3JM9t4/kytz35DkuF9MxqkGGEHNauEbaARdm2fafnOyw1s0tIQDPKF/7bkP1u3dbrmjpn5CelyA==";
      };
    };
    "@ethersproject/signing-key-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_signing-key";
      packageName = "@ethersproject/signing-key";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/signing-key"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/signing-key"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/signing-key/-/signing-key-5.6.0.tgz";
        sha512 = "S+njkhowmLeUu/r7ir8n78OUKx63kBdMCPssePS89So1TH4hZqnWFsThEd/GiXYp9qMxVrydf7KdM9MTGPFukA==";
      };
    };
    "@ethersproject/solidity-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_solidity";
      packageName = "@ethersproject/solidity";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/solidity"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/solidity"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/solidity/-/solidity-5.6.0.tgz";
        sha512 = "YwF52vTNd50kjDzqKaoNNbC/r9kMDPq3YzDWmsjFTRBcIF1y4JCQJ8gB30wsTfHbaxgxelI5BfxQSxD/PbJOww==";
      };
    };
    "@ethersproject/strings-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_strings";
      packageName = "@ethersproject/strings";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/strings"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/strings"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/strings/-/strings-5.6.0.tgz";
        sha512 = "uv10vTtLTZqrJuqBZR862ZQjTIa724wGPWQqZrofaPI/kUsf53TBG0I0D+hQ1qyNtllbNzaW+PDPHHUI6/65Mg==";
      };
    };
    "@ethersproject/transactions-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_transactions";
      packageName = "@ethersproject/transactions";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/transactions"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/transactions"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/transactions/-/transactions-5.6.0.tgz";
        sha512 = "4HX+VOhNjXHZyGzER6E/LVI2i6lf9ejYeWD6l4g50AdmimyuStKc39kvKf1bXWQMg7QNVh+uC7dYwtaZ02IXeg==";
      };
    };
    "@ethersproject/units-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_units";
      packageName = "@ethersproject/units";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/units"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/units"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/units/-/units-5.6.0.tgz";
        sha512 = "tig9x0Qmh8qbo1w8/6tmtyrm/QQRviBh389EQ+d8fP4wDsBrJBf08oZfoiz1/uenKK9M78yAP4PoR7SsVoTjsw==";
      };
    };
    "@ethersproject/wallet-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_wallet";
      packageName = "@ethersproject/wallet";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/wallet"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/wallet"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/wallet/-/wallet-5.6.0.tgz";
        sha512 = "qMlSdOSTyp0MBeE+r7SUhr1jjDlC1zAXB8VD84hCnpijPQiSNbxr6GdiLXxpUs8UKzkDiNYYC5DRI3MZr+n+tg==";
      };
    };
    "@ethersproject/web-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_web";
      packageName = "@ethersproject/web";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/web"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/web"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/web/-/web-5.6.0.tgz";
        sha512 = "G/XHj0hV1FxI2teHRfCGvfBUHFmU+YOSbCxlAMqJklxSa7QMiHFQfAxvwY2PFqgvdkxEKwRNr/eCjfAPEm2Ctg==";
      };
    };
    "@ethersproject/wordlists-5.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_ethersproject_slash_wordlists";
      packageName = "@ethersproject/wordlists";
      version = "5.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@ethersproject/wordlists"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@ethersproject/wordlists"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@ethersproject/wordlists/-/wordlists-5.6.0.tgz";
        sha512 = "q0bxNBfIX3fUuAo9OmjlEYxP40IB8ABgb7HjEZCL5IKubzV3j30CWi2rqQbjTS2HfoyQbfINoKcTVWP4ejwR7Q==";
      };
    };
    "@randlabs/communication-bridge-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_randlabs_slash_communication-bridge";
      packageName = "@randlabs/communication-bridge";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@randlabs/communication-bridge"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@randlabs/communication-bridge"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@randlabs/communication-bridge/-/communication-bridge-1.0.0.tgz";
        sha512 = "CuJNwtMTG1LHR1LQNWUPv+8xPUdkRY9p61wGJEp8J/N3q8djmnMySvSQlyVqLBvXsTPKmYc0ZmfXEXCpb5P5Cw==";
      };
    };
    "@randlabs/myalgo-connect-1.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_randlabs_slash_myalgo-connect";
      packageName = "@randlabs/myalgo-connect";
      version = "1.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@randlabs/myalgo-connect"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@randlabs/myalgo-connect"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@randlabs/myalgo-connect/-/myalgo-connect-1.1.2.tgz";
        sha512 = "UPsdWfZmnRvEuGL83MNolSzVRDfCo4cURA5Bxi9whRcoglEte3hUgEwbxesaeCnpByvgLNYM9YBbjBb8Bh9PqQ==";
      };
    };
    "@sindresorhus/is-4.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_sindresorhus_slash_is";
      packageName = "@sindresorhus/is";
      version = "4.6.0";
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
        url = "https://registry.npmjs.org/@sindresorhus/is/-/is-4.6.0.tgz";
        sha512 = "t09vSN3MdfsyCHoFcTRCH/iUtG7OJ0CsjzB8cjAmKc/va/kIgeDI/TxsigdncE/4be734m0cvIYwNaV4i2XqAw==";
      };
    };
    "@solana/buffer-layout-3.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_solana_slash_buffer-layout";
      packageName = "@solana/buffer-layout";
      version = "3.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@solana/buffer-layout"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@solana/buffer-layout"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@solana/buffer-layout/-/buffer-layout-3.0.0.tgz";
        sha512 = "MVdgAKKL39tEs0l8je0hKaXLQFb7Rdfb0Xg2LjFZd8Lfdazkg6xiS98uAZrEKvaoF3i4M95ei9RydkGIDMeo3w==";
      };
    };
    "@solana/wallet-adapter-base-0.9.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_solana_slash_wallet-adapter-base";
      packageName = "@solana/wallet-adapter-base";
      version = "0.9.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@solana/wallet-adapter-base"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@solana/wallet-adapter-base"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@solana/wallet-adapter-base/-/wallet-adapter-base-0.9.5.tgz";
        sha512 = "KCrSB2s8lA38Bd+aPvHlwPEHZU1owD6LSCikjumUaR3HCcpv+V1lxgQX+tdNaDyEVTKlAYNd0uJU+yQfQlkiOA==";
      };
    };
    "@solana/web3.js-1.36.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_solana_slash_web3.js";
      packageName = "@solana/web3.js";
      version = "1.36.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@solana/web3.js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@solana/web3.js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@solana/web3.js/-/web3.js-1.36.0.tgz";
        sha512 = "RNT1451iRR7TyW7EJKMCrH/0OXawIe4zVm0DWQASwXlR/u1jmW6FrmH0lujIh7cGTlfOVbH+2ZU9AVUPLBFzwA==";
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
    "@tsconfig/node10-1.0.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_tsconfig_slash_node10";
      packageName = "@tsconfig/node10";
      version = "1.0.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@tsconfig/node10"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@tsconfig/node10"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@tsconfig/node10/-/node10-1.0.8.tgz";
        sha512 = "6XFfSQmMgq0CFLY1MslA/CPUfhIL919M1rMsa5lP2P097N2Wd1sSX0tx1u4olM16fLNhtHZpRhedZJphNJqmZg==";
      };
    };
    "@tsconfig/node12-1.0.9" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_tsconfig_slash_node12";
      packageName = "@tsconfig/node12";
      version = "1.0.9";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@tsconfig/node12"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@tsconfig/node12"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@tsconfig/node12/-/node12-1.0.9.tgz";
        sha512 = "/yBMcem+fbvhSREH+s14YJi18sp7J9jpuhYByADT2rypfajMZZN4WQ6zBGgBKp53NKmqI36wFYDb3yaMPurITw==";
      };
    };
    "@tsconfig/node14-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_tsconfig_slash_node14";
      packageName = "@tsconfig/node14";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@tsconfig/node14"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@tsconfig/node14"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@tsconfig/node14/-/node14-1.0.1.tgz";
        sha512 = "509r2+yARFfHHE7T6Puu2jjkoycftovhXRqW328PDXTVGKihlb1P8Z9mMZH04ebyajfRY7dedfGynlrFHJUQCg==";
      };
    };
    "@tsconfig/node16-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_tsconfig_slash_node16";
      packageName = "@tsconfig/node16";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@tsconfig/node16"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@tsconfig/node16"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@tsconfig/node16/-/node16-1.0.2.tgz";
        sha512 = "eZxlbI8GZscaGS7kkc/trHTT5xgrjH3/1n2JDwusC9iahPKWMRvRjJSAN5mCXviuTGQ/lHnhvv8Q1YTpnfz9gA==";
      };
    };
    "@types/axios-0.14.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_axios";
      packageName = "@types/axios";
      version = "0.14.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/axios"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/axios"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/axios/-/axios-0.14.0.tgz";
        sha1 = "ec2300fbe7d7dddd7eb9d3abf87999964cafce46";
      };
    };
    "@types/bn.js-4.11.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_bn.js";
      packageName = "@types/bn.js";
      version = "4.11.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/bn.js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/bn.js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/bn.js/-/bn.js-4.11.6.tgz";
        sha512 = "pqr857jrp2kPuO9uRjZ3PwnJTjoQy+fcdxvBTvHm6dkmEL9q+hDD/2j/0ELOBPtPnS8LjCX0gI9nbl8lVkadpg==";
      };
    };
    "@types/bs58-4.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_bs58";
      packageName = "@types/bs58";
      version = "4.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/bs58"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/bs58"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/bs58/-/bs58-4.0.1.tgz";
        sha512 = "yfAgiWgVLjFCmRv8zAcOIHywYATEwiTVccTLnRp6UxTNavT55M9d/uhK3T03St/+8/z/wW+CRjGKUNmEqoHHCA==";
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
    "@types/connect-3.4.35" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_connect";
      packageName = "@types/connect";
      version = "3.4.35";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/connect"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/connect"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/connect/-/connect-3.4.35.tgz";
        sha512 = "cdeYyv4KWoEgpBISTxWvqYsVy444DOqehiF3fM3ne10AmJ62RSyNkUnxMJXHQWRQQX2eR94m5y1IZyDwBjV9FQ==";
      };
    };
    "@types/express-serve-static-core-4.17.28" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_express-serve-static-core";
      packageName = "@types/express-serve-static-core";
      version = "4.17.28";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/express-serve-static-core"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/express-serve-static-core"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/express-serve-static-core/-/express-serve-static-core-4.17.28.tgz";
        sha512 = "P1BJAEAW3E2DJUlkgq4tOL3RyMunoWXqbSCygWo5ZIWTjUgN1YnaXWW4VWl/oc8vs/XoYibEGBKP0uZyF4AHig==";
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
    "@types/lodash-4.14.179" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_lodash";
      packageName = "@types/lodash";
      version = "4.14.179";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/lodash"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/lodash"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/lodash/-/lodash-4.14.179.tgz";
        sha512 = "uwc1x90yCKqGcIOAT6DwOSuxnrAbpkdPsUOZtwrXb4D/6wZs+6qG7QnIawDuZWg0sWpxl+ltIKCaLoMlna678w==";
      };
    };
    "@types/multistream-2.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_multistream";
      packageName = "@types/multistream";
      version = "2.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/multistream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/multistream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/multistream/-/multistream-2.1.2.tgz";
        sha512 = "Q0LINZC7Q2HE+M7uMh2QZp54F/4wz+8Vs6IEXCmeboxb3EScvqczARXPmGjP8GrEbLf68haIUjfWuQw9/kB63w==";
      };
    };
    "@types/node-12.20.46" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_node";
      packageName = "@types/node";
      version = "12.20.46";
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
        url = "https://registry.npmjs.org/@types/node/-/node-12.20.46.tgz";
        sha512 = "cPjLXj8d6anFPzFvOPxS3fvly3Shm5nTfl6g8X5smexixbuGUf7hfr21J5tX9JW+UPStp/5P5R8qrKL5IyVJ+A==";
      };
    };
    "@types/node-17.0.21" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_node";
      packageName = "@types/node";
      version = "17.0.21";
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
        url = "https://registry.npmjs.org/@types/node/-/node-17.0.21.tgz";
        sha512 = "DBZCJbhII3r90XbQxI8Y9IjjiiOGlZ0Hr32omXIZvwwZ7p4DMMXGrKXVyPfuoBOri9XNtL0UK69jYIBIsRX3QQ==";
      };
    };
    "@types/qs-6.9.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_qs";
      packageName = "@types/qs";
      version = "6.9.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/qs"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/qs"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/qs/-/qs-6.9.7.tgz";
        sha512 = "FGa1F62FT09qcrueBA6qYTrJPVDzah9a+493+o2PCXsesWHIn27G98TsSMs3WPNbZIEj4+VJf6saSFpvD+3Zsw==";
      };
    };
    "@types/range-parser-1.2.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_range-parser";
      packageName = "@types/range-parser";
      version = "1.2.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/range-parser"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/range-parser"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/range-parser/-/range-parser-1.2.4.tgz";
        sha512 = "EEhsLsD6UsDM1yFhAvy0Cjr6VwmpMWqFBCb9w07wVugF7w9nfajxLuVmngTIpgS6svCnm6Vaw+MZhoDCKnOfsw==";
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
    "@types/secp256k1-4.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_secp256k1";
      packageName = "@types/secp256k1";
      version = "4.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/secp256k1"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/secp256k1"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/secp256k1/-/secp256k1-4.0.3.tgz";
        sha512 = "Da66lEIFeIz9ltsdMZcpQvmrmmoqrfju8pm1BH8WbYjZSwUgCwXLb9C+9XYogwBITnbsSaMdVPb2ekf7TV+03w==";
      };
    };
    "@types/ws-7.4.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "_at_types_slash_ws";
      packageName = "@types/ws";
      version = "7.4.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "@types/ws"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "@types/ws"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/@types/ws/-/ws-7.4.7.tgz";
        sha512 = "JQbbmxZTZehdc2iszGKs5oC3NFnjeay7mtAWrdt7qNtAVK0g19muApzAy4bm9byz79xa2ZnO/BOBC2R8RC5Lww==";
      };
    };
    "JSONStream-1.3.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "JSONStream";
      packageName = "JSONStream";
      version = "1.3.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "JSONStream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "JSONStream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/JSONStream/-/JSONStream-1.3.5.tgz";
        sha512 = "E+iruNOY8VV9s4JEbe1aNEm6MiszPRr/UfcHMz0TQh1BXSxHK+ASV1R6W4HpjBhSeS+54PIsAMCBmwD06LLsqQ==";
      };
    };
    "acorn-8.7.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "acorn";
      packageName = "acorn";
      version = "8.7.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "acorn"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "acorn"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/acorn/-/acorn-8.7.0.tgz";
        sha512 = "V/LGr1APy+PXIwKebEWrkZPwoeoF+w1jiOBUmuxuiUIaOHtob8Qc9BTrYo7VuI5fR8tqsy+buA2WFooR5olqvQ==";
      };
    };
    "acorn-walk-8.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "acorn-walk";
      packageName = "acorn-walk";
      version = "8.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "acorn-walk"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "acorn-walk"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/acorn-walk/-/acorn-walk-8.2.0.tgz";
        sha512 = "k+iyHEuPgSw6SbuDpGQM+06HQUa04DZ3o+F6CSzXMvvI5KMvnaEqXe+YVe555R9nn6GPt404fos4wcgpw12SDA==";
      };
    };
    "aes-js-3.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "aes-js";
      packageName = "aes-js";
      version = "3.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "aes-js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "aes-js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/aes-js/-/aes-js-3.0.0.tgz";
        sha1 = "e21df10ad6c2053295bcbb8dab40b09dbea87e4d";
      };
    };
    "algo-msgpack-with-bigint-2.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "algo-msgpack-with-bigint";
      packageName = "algo-msgpack-with-bigint";
      version = "2.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "algo-msgpack-with-bigint"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "algo-msgpack-with-bigint"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/algo-msgpack-with-bigint/-/algo-msgpack-with-bigint-2.1.1.tgz";
        sha512 = "F1tGh056XczEaEAqu7s+hlZUDWwOBT70Eq0lfMpBP2YguSQVyxRbprLq5rELXKQOyOaixTWYhMeMQMzP0U5FoQ==";
      };
    };
    "algosdk-1.14.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "algosdk";
      packageName = "algosdk";
      version = "1.14.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "algosdk"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "algosdk"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/algosdk/-/algosdk-1.14.0.tgz";
        sha512 = "IaaomouKmuCnK+xLuz27X8DQro0ZjVyw4zHvV8HJap9PPDOQKbvpm+UIIsEf0CmC0xWPXIxfFbmlJ0y5CeGlqQ==";
      };
    };
    "arconnect-0.2.9" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "arconnect";
      packageName = "arconnect";
      version = "0.2.9";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "arconnect"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "arconnect"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/arconnect/-/arconnect-0.2.9.tgz";
        sha512 = "Us49eN/+8l6BrkAPdXnJVPwWlxxUPR7QaBjA0j3OBAcioIFRpwTdoPN9FxtwDGN91lgM6ebOudTXJToRiNizoA==";
      };
    };
    "arg-4.1.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "arg";
      packageName = "arg";
      version = "4.1.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "arg"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "arg"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/arg/-/arg-4.1.3.tgz";
        sha512 = "58S9QDqG0Xx27YwPSt9fJxivjYl432YCwfDMfZ+71RAqUrZef7LrKQZ3LHLOwCS4FLNBplP533Zx895SeOCHvA==";
      };
    };
    "arweave-1.10.23" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "arweave";
      packageName = "arweave";
      version = "1.10.23";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "arweave"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "arweave"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/arweave/-/arweave-1.10.23.tgz";
        sha512 = "lAeCopS9iNGhmJkUovWqb7R+JEF83LP8f51rG+H98JPI9KQVRJYtM5NmMMU8auDtOzvBPTZ7me1pYn/CfS3VTg==";
      };
    };
    "arweave-stream-tx-1.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "arweave-stream-tx";
      packageName = "arweave-stream-tx";
      version = "1.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "arweave-stream-tx"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "arweave-stream-tx"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/arweave-stream-tx/-/arweave-stream-tx-1.1.0.tgz";
        sha512 = "1BEYGFSP+FP1ACfclTjSjSTWx5PV/7a+0TwGZu+MlkmnnZTQ3hCOr5Md2Pi/T6dc69Fj+BRezSckiIhKFwTc3g==";
      };
    };
    "asn1.js-5.4.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "asn1.js";
      packageName = "asn1.js";
      version = "5.4.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "asn1.js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "asn1.js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/asn1.js/-/asn1.js-5.4.1.tgz";
        sha512 = "+I//4cYPccV8LdmBLiX8CYvf9Sp3vQsrqu2QNXRcrbiWvcx/UdlFiqUJJzxRQxgsZmvhXhn4cSKeSmoFjVdupA==";
      };
    };
    "async-3.2.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "async";
      packageName = "async";
      version = "3.2.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "async"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "async"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/async/-/async-3.2.3.tgz";
        sha512 = "spZRyzKL5l5BZQrr/6m/SqFdBN0q3OCI0f9rjfBzCMBIP4p75P620rR3gTmaksNOhmzgdxcaxdNfMy6anrbM0g==";
      };
    };
    "asynckit-0.4.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "asynckit";
      packageName = "asynckit";
      version = "0.4.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "asynckit"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "asynckit"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/asynckit/-/asynckit-0.4.0.tgz";
        sha1 = "c79ed97f7f34cb8f2ba1bc9790bcc366474b4b79";
      };
    };
    "available-typed-arrays-1.0.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "available-typed-arrays";
      packageName = "available-typed-arrays";
      version = "1.0.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "available-typed-arrays"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "available-typed-arrays"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/available-typed-arrays/-/available-typed-arrays-1.0.5.tgz";
        sha512 = "DMD0KiN46eipeziST1LPP/STfDU0sufISXmjSgvVsoU2tqxctQeASejWcfNtxYKqETM1UxQ8sp2OrSBWpHY6sw==";
      };
    };
    "avsc-5.7.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "avsc";
      packageName = "avsc";
      version = "5.7.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "avsc"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "avsc"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/avsc/-/avsc-5.7.3.tgz";
        sha512 = "uUbetCWczQHbsKyX1C99XpQHBM8SWfovvaZhPIj23/1uV7SQf0WeRZbiLpw0JZm+LHTChfNgrLfDJOVoU2kU+A==";
      };
    };
    "axios-0.21.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "axios";
      packageName = "axios";
      version = "0.21.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "axios"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "axios"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/axios/-/axios-0.21.4.tgz";
        sha512 = "ut5vewkiu8jjGBdqpM44XxjuCjq9LAKeHVmoVfHVzy8eHgxxq8SbAVQNovDA8mVi05kP0Ea/n/UzcSHcTJQfNg==";
      };
    };
    "axios-0.22.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "axios";
      packageName = "axios";
      version = "0.22.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "axios"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "axios"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/axios/-/axios-0.22.0.tgz";
        sha512 = "Z0U3uhqQeg1oNcihswf4ZD57O3NrR1+ZXhxaROaWpDmsDTx7T2HNBV2ulBtie2hwJptu8UvgnJoK+BIqdzh/1w==";
      };
    };
    "balanced-match-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "balanced-match";
      packageName = "balanced-match";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "balanced-match"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "balanced-match"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/balanced-match/-/balanced-match-1.0.2.tgz";
        sha512 = "3oSeUO0TMV67hN1AmbXsK4yaqU7tjiHlbxRDZOpH0KW9+CeX4bRAaX0Anxt0tx2MrpRpWwQaPwIlISEJhYU5Pw==";
      };
    };
    "base-x-3.0.9" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "base-x";
      packageName = "base-x";
      version = "3.0.9";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "base-x"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "base-x"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/base-x/-/base-x-3.0.9.tgz";
        sha512 = "H7JU6iBHTal1gp56aKoaa//YUxEaAOUiydvrV/pILqIHXTtqxSkATOnDA2u+jZ/61sD+L/412+7kzXRtWukhpQ==";
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
    "base64url-3.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "base64url";
      packageName = "base64url";
      version = "3.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "base64url"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "base64url"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/base64url/-/base64url-3.0.1.tgz";
        sha512 = "ir1UPr3dkwexU7FdV8qBBbNDRUhMmIekYMFZfi+C/sLNnRESKPl23nB9b2pltqfOQNnGzsDdId90AEtG5tCx4A==";
      };
    };
    "bech32-1.1.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "bech32";
      packageName = "bech32";
      version = "1.1.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "bech32"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "bech32"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/bech32/-/bech32-1.1.4.tgz";
        sha512 = "s0IrSOzLlbvX7yp4WBfPITzpAU8sqQcpsmwXDiKwrG4r491vwCO/XpejasRNl0piBMe/DvP4Tz0mIS/X1DPJBQ==";
      };
    };
    "bignumber.js-9.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "bignumber.js";
      packageName = "bignumber.js";
      version = "9.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "bignumber.js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "bignumber.js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/bignumber.js/-/bignumber.js-9.0.2.tgz";
        sha512 = "GAcQvbpsM0pUb0zw1EI0KhQEZ+lRwR5fYaAp3vPOYuP7aDvGy6cVN6XHLauvF8SOga2y0dcLcjt3iQDTSEliyw==";
      };
    };
    "bn.js-4.12.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "bn.js";
      packageName = "bn.js";
      version = "4.12.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "bn.js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "bn.js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/bn.js/-/bn.js-4.12.0.tgz";
        sha512 = "c98Bf3tPniI+scsdk237ku1Dc3ujXQTSgyiPUDEOe7tRkhrqridvh8klBv0HCEso1OLOYcHuCv/cS6DNxKH+ZA==";
      };
    };
    "bn.js-5.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "bn.js";
      packageName = "bn.js";
      version = "5.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "bn.js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "bn.js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/bn.js/-/bn.js-5.2.0.tgz";
        sha512 = "D7iWRBvnZE8ecXiLj/9wbxH7Tk79fAh8IHaTNq1RWRixsS02W+5qS+iE9yq6RYl0asXx5tw0bLhmT5pIfbSquw==";
      };
    };
    "borsh-0.4.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "borsh";
      packageName = "borsh";
      version = "0.4.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "borsh"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "borsh"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/borsh/-/borsh-0.4.0.tgz";
        sha512 = "aX6qtLya3K0AkT66CmYWCCDr77qsE9arV05OmdFpmat9qu8Pg9J5tBUPDztAW5fNh/d/MyVG/OYziP52Ndzx1g==";
      };
    };
    "brace-expansion-1.1.11" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "brace-expansion";
      packageName = "brace-expansion";
      version = "1.1.11";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "brace-expansion"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "brace-expansion"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/brace-expansion/-/brace-expansion-1.1.11.tgz";
        sha512 = "iCuPHDFgrHX7H2vEI/5xpz07zSHB00TpugqhmYtVmMO6518mCuRMoOYFldEBl0g187ufozdaHgWKcYFb61qGiA==";
      };
    };
    "brorand-1.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "brorand";
      packageName = "brorand";
      version = "1.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "brorand"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "brorand"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/brorand/-/brorand-1.1.0.tgz";
        sha1 = "12c25efe40a45e3c323eb8675a0a0ce57b22371f";
      };
    };
    "bs58-4.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "bs58";
      packageName = "bs58";
      version = "4.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "bs58"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "bs58"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/bs58/-/bs58-4.0.1.tgz";
        sha1 = "be161e76c354f6f788ae4071f63f34e8c4f0a42a";
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
    "buffer-6.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "buffer";
      packageName = "buffer";
      version = "6.0.1";
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
        url = "https://registry.npmjs.org/buffer/-/buffer-6.0.1.tgz";
        sha512 = "rVAXBwEcEoYtxnHSO5iWyhzV/O1WMtkUYWlfdLS7FjU4PnSJJHEfHXi/uHPI5EwltmOA794gN3bm3/pzuctWjQ==";
      };
    };
    "buffer-6.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "buffer";
      packageName = "buffer";
      version = "6.0.3";
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
        url = "https://registry.npmjs.org/buffer/-/buffer-6.0.3.tgz";
        sha512 = "FTiCpNxtwiZZHEZbcbTIcZjERVICn9yq/pDFkTl95/AxzD1naBctN7YO68riM/gLSDY7sdrMby8hofADYuuqOA==";
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
    "call-bind-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "call-bind";
      packageName = "call-bind";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "call-bind"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "call-bind"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/call-bind/-/call-bind-1.0.2.tgz";
        sha512 = "7O+FbCihrB5WGbFYesctwmTKae6rOiIzmz1icreWJ+0aA7LJfuqhEso2T9ncpcFtzMQtzXf2QGGueWJGTYsqrA==";
      };
    };
    "circular-json-0.5.9" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "circular-json";
      packageName = "circular-json";
      version = "0.5.9";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "circular-json"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "circular-json"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/circular-json/-/circular-json-0.5.9.tgz";
        sha512 = "4ivwqHpIFJZBuhN3g/pEcdbnGUywkBblloGbkglyloVjjR3uT6tieI89MVOfbP2tHX5sgb01FuLgAOzebNlJNQ==";
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
    "color-3.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "color";
      packageName = "color";
      version = "3.2.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "color"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "color"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/color/-/color-3.2.1.tgz";
        sha512 = "aBl7dZI9ENN6fUGC7mWpMTPNHmWUSNan9tuWN6ahh5ZLNk9baLJOnSMlrQkHcrfFgz2/RigjUVAjdx36VcemKA==";
      };
    };
    "color-convert-1.9.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "color-convert";
      packageName = "color-convert";
      version = "1.9.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "color-convert"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "color-convert"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/color-convert/-/color-convert-1.9.3.tgz";
        sha512 = "QfAUtd+vFdAtFQcC8CCyYt1fYWxSqAiK2cSD6zDB8N3cpsEBAvRxp9zOGg6G/SHHJYAT88/az/IuDGALsNVbGg==";
      };
    };
    "color-name-1.1.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "color-name";
      packageName = "color-name";
      version = "1.1.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "color-name"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "color-name"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/color-name/-/color-name-1.1.3.tgz";
        sha1 = "a7d0558bd89c42f795dd42328f740831ca53bc25";
      };
    };
    "color-string-1.9.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "color-string";
      packageName = "color-string";
      version = "1.9.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "color-string"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "color-string"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/color-string/-/color-string-1.9.0.tgz";
        sha512 = "9Mrz2AQLefkH1UvASKj6v6hj/7eWgjnT/cVsR8CumieLoT+g900exWeNogqtweI8dxloXN9BDQTYro1oWu/5CQ==";
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
    "colorspace-1.1.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "colorspace";
      packageName = "colorspace";
      version = "1.1.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "colorspace"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "colorspace"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/colorspace/-/colorspace-1.1.4.tgz";
        sha512 = "BgvKJiuVu1igBUF2kEjRCZXol6wiiGbY5ipL/oVPwm0BL9sIpMIzM8IK7vwuxIIzOXMV3Ey5w+vxhm0rR/TN8w==";
      };
    };
    "combined-stream-1.0.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "combined-stream";
      packageName = "combined-stream";
      version = "1.0.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "combined-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "combined-stream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/combined-stream/-/combined-stream-1.0.8.tgz";
        sha512 = "FQN4MRfuJeHf7cBbBMJFXhKSDq+2kAArBlmRBvcvFE5BB1HZKXtSFASDhdlz9zOYwxh8lDdnvmMOe/+5cdoEdg==";
      };
    };
    "commander-2.20.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "commander";
      packageName = "commander";
      version = "2.20.3";
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
        url = "https://registry.npmjs.org/commander/-/commander-2.20.3.tgz";
        sha512 = "GpVkmM8vF2vQUkj2LvZmD35JxeJOLCwJ9cUkugyk2nuhbv3+mJvpLYYt+0+USMxE+oj+ey/lJEnhZw75x/OMcQ==";
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
    "component-emitter-1.3.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "component-emitter";
      packageName = "component-emitter";
      version = "1.3.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "component-emitter"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "component-emitter"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/component-emitter/-/component-emitter-1.3.0.tgz";
        sha512 = "Rd3se6QB+sO1TwqZjscQrurpEPIfO0/yYnSin6Q/rD3mOutHvUrCAhJub3r90uNb+SESBuE0QYoB90YdfatsRg==";
      };
    };
    "concat-map-0.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "concat-map";
      packageName = "concat-map";
      version = "0.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "concat-map"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "concat-map"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/concat-map/-/concat-map-0.0.1.tgz";
        sha1 = "d8a96bd77fd68df7793a73036a3ba0d5405d477b";
      };
    };
    "cookiejar-2.1.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "cookiejar";
      packageName = "cookiejar";
      version = "2.1.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "cookiejar"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "cookiejar"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/cookiejar/-/cookiejar-2.1.3.tgz";
        sha512 = "JxbCBUdrfr6AQjOXrxoTvAMJO4HBTUIlBzslcJPAz+/KT8yk53fXun51u+RenNYvad/+Vc2DIz5o9UxlCDymFQ==";
      };
    };
    "core-util-is-1.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "core-util-is";
      packageName = "core-util-is";
      version = "1.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "core-util-is"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "core-util-is"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/core-util-is/-/core-util-is-1.0.3.tgz";
        sha512 = "ZQBvi1DcpJ4GDqanjucZ2Hj3wEO5pZDS89BWbkcrvdxksJorwUDDZamX9ldFkp9aw2lmBDLgkObEA4DWNJ9FYQ==";
      };
    };
    "create-require-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "create-require";
      packageName = "create-require";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "create-require"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "create-require"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/create-require/-/create-require-1.1.1.tgz";
        sha512 = "dcKFX3jn0MpIaXjisoRvexIJVEKzaq7z2rZKxf+MSr9TkdmHmsU4m2lcLojrj/FHl8mk5VxMmYA+ftRkP/3oKQ==";
      };
    };
    "cross-fetch-3.1.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "cross-fetch";
      packageName = "cross-fetch";
      version = "3.1.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "cross-fetch"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "cross-fetch"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/cross-fetch/-/cross-fetch-3.1.5.tgz";
        sha512 = "lvb1SBsI0Z7GDwmuid+mU3kWVBwTVUbe7S0H52yaaAdQOXq2YktTCZdlAcNKFzE6QtRz0snpw9bNiPeOIkkQvw==";
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
    "define-properties-1.1.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "define-properties";
      packageName = "define-properties";
      version = "1.1.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "define-properties"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "define-properties"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/define-properties/-/define-properties-1.1.3.tgz";
        sha512 = "3MqfYKj2lLzdMSf8ZIZE/V+Zuy+BgD6f164e8K2w7dgnpKArBDerGYpM46IYYcjnkdPNMjPk9A6VFB8+3SKlXQ==";
      };
    };
    "delay-5.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "delay";
      packageName = "delay";
      version = "5.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "delay"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "delay"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/delay/-/delay-5.0.0.tgz";
        sha512 = "ReEBKkIfe4ya47wlPYf/gu5ib6yUG0/Aez0JQZQz94kiWtRQvZIQbTiehsnwHvLSWJnQdhVeqYue7Id1dKr0qw==";
      };
    };
    "delayed-stream-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "delayed-stream";
      packageName = "delayed-stream";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "delayed-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "delayed-stream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/delayed-stream/-/delayed-stream-1.0.0.tgz";
        sha1 = "df3ae199acadfb7d440aaae0b29e2272b24ec619";
      };
    };
    "diff-4.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "diff";
      packageName = "diff";
      version = "4.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "diff"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "diff"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/diff/-/diff-4.0.2.tgz";
        sha512 = "58lmxKSA4BNyLz+HHMUzlOEpg09FV+ev6ZMe3vJihgdxzgcwZ8VoEEPmALCZG9LmqfVoNMMKpttIYTVG6uDY7A==";
      };
    };
    "elliptic-6.5.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "elliptic";
      packageName = "elliptic";
      version = "6.5.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "elliptic"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "elliptic"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/elliptic/-/elliptic-6.5.4.tgz";
        sha512 = "iLhC6ULemrljPZb+QutR5TQGB+pdW6KGD5RSegS+8sorOZT+rdQFbsQFJgvN3eRqNALqJer4oQ16YvJHlU8hzQ==";
      };
    };
    "enabled-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "enabled";
      packageName = "enabled";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "enabled"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "enabled"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/enabled/-/enabled-2.0.0.tgz";
        sha512 = "AKrN98kuwOzMIdAizXGI86UFBoo26CL21UM763y1h/GMSJ4/OHU9k2YlsmBpyScFo/wbLzWQJBMCW4+IO3/+OQ==";
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
    "es-abstract-1.19.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "es-abstract";
      packageName = "es-abstract";
      version = "1.19.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "es-abstract"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "es-abstract"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/es-abstract/-/es-abstract-1.19.1.tgz";
        sha512 = "2vJ6tjA/UfqLm2MPs7jxVybLoB8i1t1Jd9R3kISld20sIxPcTbLuggQOUxeWeAvIUkduv/CfMjuh4WmiXr2v9w==";
      };
    };
    "es-to-primitive-1.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "es-to-primitive";
      packageName = "es-to-primitive";
      version = "1.2.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "es-to-primitive"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "es-to-primitive"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/es-to-primitive/-/es-to-primitive-1.2.1.tgz";
        sha512 = "QCOllgZJtaUo9miYBcLChTUaHNjJF3PYs1VidD7AwiEj1kYxKeQTctLAezAOH5ZKRH0g2IgPn6KwB4IT8iRpvA==";
      };
    };
    "es6-promise-4.2.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "es6-promise";
      packageName = "es6-promise";
      version = "4.2.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "es6-promise"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "es6-promise"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/es6-promise/-/es6-promise-4.2.8.tgz";
        sha512 = "HJDGx5daxeIvxdBxvG2cb9g4tEvwIk3i8+nhX0yGrYmZUzbkdg8QbDevheDB8gd0//uPj4c1EQua8Q+MViT0/w==";
      };
    };
    "es6-promisify-5.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "es6-promisify";
      packageName = "es6-promisify";
      version = "5.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "es6-promisify"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "es6-promisify"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/es6-promisify/-/es6-promisify-5.0.0.tgz";
        sha1 = "5109d62f3e56ea967c4b63505aef08291c8a5203";
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
    "ethers-5.6.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ethers";
      packageName = "ethers";
      version = "5.6.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ethers"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ethers"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/ethers/-/ethers-5.6.1.tgz";
        sha512 = "qtl/2W+dwmUa5Z3JqwsbV3JEBZZHNARe5K/A2ePcNAuhJYnEKIgGOT/O9ouPwBijSqVoQnmQMzi5D48LFNOY2A==";
      };
    };
    "eventemitter3-4.0.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "eventemitter3";
      packageName = "eventemitter3";
      version = "4.0.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "eventemitter3"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "eventemitter3"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/eventemitter3/-/eventemitter3-4.0.7.tgz";
        sha512 = "8guHBZCwKnFhYdHr2ysuRWErTwhoN2X8XELRlrRwpmfeY2jjuUN4taQMsULKUVo1K4DvZl+0pgfyoysHxvmvEw==";
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
    "exponential-backoff-3.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "exponential-backoff";
      packageName = "exponential-backoff";
      version = "3.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "exponential-backoff"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "exponential-backoff"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/exponential-backoff/-/exponential-backoff-3.1.0.tgz";
        sha512 = "oBuz5SYz5zzyuHINoe9ooePwSu0xApKWgeNzok4hZ5YKXFh9zrQBEM15CXqoZkJJPuI2ArvqjPQd8UKJA753XA==";
      };
    };
    "eyes-0.1.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "eyes";
      packageName = "eyes";
      version = "0.1.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "eyes"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "eyes"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/eyes/-/eyes-0.1.8.tgz";
        sha1 = "62cf120234c683785d902348a800ef3e0cc20bc0";
      };
    };
    "fast-safe-stringify-2.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "fast-safe-stringify";
      packageName = "fast-safe-stringify";
      version = "2.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "fast-safe-stringify"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "fast-safe-stringify"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/fast-safe-stringify/-/fast-safe-stringify-2.1.1.tgz";
        sha512 = "W+KJc2dmILlPplD/H4K9l9LcAHAfPtP6BY84uVLXQ6Evcz9Lcg33Y2z1IVblT6xdY54PXYVHEv+0Wpq8Io6zkA==";
      };
    };
    "fecha-4.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "fecha";
      packageName = "fecha";
      version = "4.2.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "fecha"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "fecha"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/fecha/-/fecha-4.2.1.tgz";
        sha512 = "MMMQ0ludy/nBs1/o0zVOiKTpG7qMbonKUzjJgQFEuvq6INZ1OraKPRAWkBq5vlKLOUMpmNYG1JoN3oDPUQ9m3Q==";
      };
    };
    "fn.name-1.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "fn.name";
      packageName = "fn.name";
      version = "1.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "fn.name"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "fn.name"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/fn.name/-/fn.name-1.1.0.tgz";
        sha512 = "GRnmB5gPyJpAhTQdSZTSp9uaPSvl09KoYcMQtsB9rQoOmzs9dH6ffeccH+Z+cv6P68Hu5bC6JjRh4Ah/mHSNRw==";
      };
    };
    "follow-redirects-1.14.9" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "follow-redirects";
      packageName = "follow-redirects";
      version = "1.14.9";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "follow-redirects"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "follow-redirects"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/follow-redirects/-/follow-redirects-1.14.9.tgz";
        sha512 = "MQDfihBQYMcyy5dhRDJUHcw7lb2Pv/TuE6xP1vyraLukNDHKbDxDNaOE3NbCAdKQApno+GPRyo1YAp89yCjK4w==";
      };
    };
    "foreach-2.0.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "foreach";
      packageName = "foreach";
      version = "2.0.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "foreach"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "foreach"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/foreach/-/foreach-2.0.5.tgz";
        sha1 = "0bee005018aeb260d0a3af3ae658dd0136ec1b99";
      };
    };
    "form-data-3.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "form-data";
      packageName = "form-data";
      version = "3.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "form-data"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "form-data"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/form-data/-/form-data-3.0.1.tgz";
        sha512 = "RHkBKtLWUVwd7SqRIvCZMEvAMoGUp0XU+seQiZejj0COz3RI3hWP4sCv3gZWWLjJTd7rGwcsF5eKZGii0r/hbg==";
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
    "formidable-1.2.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "formidable";
      packageName = "formidable";
      version = "1.2.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "formidable"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "formidable"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/formidable/-/formidable-1.2.6.tgz";
        sha512 = "KcpbcpuLNOwrEjnbpMC0gS+X8ciDoZE1kkqzat4a8vrprf+s9pKNQ/QIwWfbfs4ltgmFl3MD177SNTkve3BwGQ==";
      };
    };
    "fs.realpath-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "fs.realpath";
      packageName = "fs.realpath";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "fs.realpath"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "fs.realpath"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/fs.realpath/-/fs.realpath-1.0.0.tgz";
        sha1 = "1504ad2523158caa40db4a2787cb01411994ea4f";
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
    "get-intrinsic-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "get-intrinsic";
      packageName = "get-intrinsic";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "get-intrinsic"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "get-intrinsic"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/get-intrinsic/-/get-intrinsic-1.1.1.tgz";
        sha512 = "kWZrnVM42QCiEA2Ig1bG8zjoIMOgxWwYCEeNdwY6Tv/cOSeGpcoX4pXHfKUxNKVoArnrEr2e9srnAxxGIraS9Q==";
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
    "get-symbol-description-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "get-symbol-description";
      packageName = "get-symbol-description";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "get-symbol-description"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "get-symbol-description"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/get-symbol-description/-/get-symbol-description-1.0.0.tgz";
        sha512 = "2EmdH1YvIQiZpltCNgkuiUnyukzxM/R6NDJX31Ke3BG1Nq5b0S2PhX59UKi9vZpPDQVdqn+1IcaAwnzTT5vCjw==";
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
    "glob-7.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "glob";
      packageName = "glob";
      version = "7.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "glob"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "glob"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/glob/-/glob-7.2.0.tgz";
        sha512 = "lmLf6gtyrPq8tTjSmrO94wBeQbFR3HbLHbuyD69wuyQkImp2hWqMGB47OX65FBkPffO641IP9jWa1z4ivqG26Q==";
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
    "has-bigints-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "has-bigints";
      packageName = "has-bigints";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "has-bigints"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has-bigints"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/has-bigints/-/has-bigints-1.0.1.tgz";
        sha512 = "LSBS2LjbNBTf6287JEbEzvJgftkF5qFkmCo9hDRpAzKhUOlJ+hx8dd4USs00SgsUNwc4617J9ki5YtEClM2ffA==";
      };
    };
    "has-symbols-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "has-symbols";
      packageName = "has-symbols";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "has-symbols"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has-symbols"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/has-symbols/-/has-symbols-1.0.2.tgz";
        sha512 = "chXa79rL/UC2KlX17jo3vRGz0azaWEx5tGqZg5pO3NUyEJVB17dMruQlzCCOfUvElghKcm5194+BCRvi2Rv/Gw==";
      };
    };
    "has-tostringtag-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "has-tostringtag";
      packageName = "has-tostringtag";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "has-tostringtag"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "has-tostringtag"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/has-tostringtag/-/has-tostringtag-1.0.0.tgz";
        sha512 = "kFjcSNhnlGV1kyoGk7OXKSawH5JOb/LzUc5w9B02hOTO0dfFRjbHQKvg1d6cf3HbeUmtU9VbbV3qzZ2Teh97WQ==";
      };
    };
    "hash.js-1.1.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "hash.js";
      packageName = "hash.js";
      version = "1.1.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "hash.js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "hash.js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/hash.js/-/hash.js-1.1.7.tgz";
        sha512 = "taOaskGt4z4SOANNseOviYDvjEJinIkRgmp7LbKP2YTTmVxWBl87s/uzK9r+44BclBSp2X7K1hqeNfz9JbBeXA==";
      };
    };
    "hi-base32-0.5.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "hi-base32";
      packageName = "hi-base32";
      version = "0.5.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "hi-base32"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "hi-base32"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/hi-base32/-/hi-base32-0.5.1.tgz";
        sha512 = "EmBBpvdYh/4XxsnUybsPag6VikPYnN30td+vQk+GI3qpahVEG9+gTkG0aXVxTjBqQ5T6ijbWIu77O+C5WFWsnA==";
      };
    };
    "hmac-drbg-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "hmac-drbg";
      packageName = "hmac-drbg";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "hmac-drbg"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "hmac-drbg"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/hmac-drbg/-/hmac-drbg-1.0.1.tgz";
        sha1 = "d2745701025a6c775a6c545793ed502fc0c649a1";
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
    "ieee754-1.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ieee754";
      packageName = "ieee754";
      version = "1.2.1";
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
        url = "https://registry.npmjs.org/ieee754/-/ieee754-1.2.1.tgz";
        sha512 = "dcyqhDvX1C46lXZcVqCpK+FtMRQVdIMN6/Df5js2zouUsqG7I6sFxitIC+7KYK29KdXOLHdu9zL4sFnoVQnqaA==";
      };
    };
    "inflight-1.0.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "inflight";
      packageName = "inflight";
      version = "1.0.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "inflight"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "inflight"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/inflight/-/inflight-1.0.6.tgz";
        sha1 = "49bd6331d7d02d0c09bc910a1075ba8165b56df9";
      };
    };
    "inherits-2.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "inherits";
      packageName = "inherits";
      version = "2.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "inherits"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "inherits"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/inherits/-/inherits-2.0.4.tgz";
        sha512 = "k/vGaX4/Yla3WzyMCvTQOXYeIHvqOKtnqBduzTHpzpQZzAskKMhZ2K+EnBiSM9zGSoIFeMpXKxa4dYeZIQqewQ==";
      };
    };
    "internal-slot-1.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "internal-slot";
      packageName = "internal-slot";
      version = "1.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "internal-slot"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "internal-slot"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/internal-slot/-/internal-slot-1.0.3.tgz";
        sha512 = "O0DB1JC/sPyZl7cIo78n5dR7eUSwwpYPiXRhTzNxZVAMUuB8vlnRFyLxdrVToks6XPLVnFfbzaVd5WLjhgg+vA==";
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
    "is-arguments-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-arguments";
      packageName = "is-arguments";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-arguments"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-arguments"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-arguments/-/is-arguments-1.1.1.tgz";
        sha512 = "8Q7EARjzEnKpt/PCD7e1cgUS0a6X8u5tdSiMqXhojOdoV9TsMsiO+9VLC5vAmO8N7/GmXn7yjR8qnA6bVAEzfA==";
      };
    };
    "is-arrayish-0.3.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-arrayish";
      packageName = "is-arrayish";
      version = "0.3.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-arrayish"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-arrayish"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-arrayish/-/is-arrayish-0.3.2.tgz";
        sha512 = "eVRqCvVlZbuw3GrM63ovNSNAeA1K16kaR/LRY/92w0zxQ5/1YzwblUX652i4Xs9RwAGjW9d9y6X88t8OaAJfWQ==";
      };
    };
    "is-bigint-1.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-bigint";
      packageName = "is-bigint";
      version = "1.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-bigint"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-bigint"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-bigint/-/is-bigint-1.0.4.tgz";
        sha512 = "zB9CruMamjym81i2JZ3UMn54PKGsQzsJeo6xvN3HJJ4CAsQNB6iRutp2To77OfCNuoxspsIhzaPoO1zyCEhFOg==";
      };
    };
    "is-boolean-object-1.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-boolean-object";
      packageName = "is-boolean-object";
      version = "1.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-boolean-object"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-boolean-object"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-boolean-object/-/is-boolean-object-1.1.2.tgz";
        sha512 = "gDYaKHJmnj4aWxyj6YHyXVpdQawtVLHU5cb+eztPGczf6cjuTdwve5ZIEfgXqH4e57An1D1AKf8CZ3kYrQRqYA==";
      };
    };
    "is-callable-1.2.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-callable";
      packageName = "is-callable";
      version = "1.2.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-callable"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-callable"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-callable/-/is-callable-1.2.4.tgz";
        sha512 = "nsuwtxZfMX67Oryl9LCQ+upnC0Z0BgpwntpS89m1H/TLF0zNfzfLMV/9Wa/6MZsj0acpEjAO0KF1xT6ZdLl95w==";
      };
    };
    "is-core-module-2.8.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-core-module";
      packageName = "is-core-module";
      version = "2.8.1";
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
        url = "https://registry.npmjs.org/is-core-module/-/is-core-module-2.8.1.tgz";
        sha512 = "SdNCUs284hr40hFTFP6l0IfZ/RSrMXF3qgoRHd3/79unUTvrFO/JoXwkGm+5J/Oe3E/b5GsnG330uUNgRpu1PA==";
      };
    };
    "is-date-object-1.0.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-date-object";
      packageName = "is-date-object";
      version = "1.0.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-date-object"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-date-object"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-date-object/-/is-date-object-1.0.5.tgz";
        sha512 = "9YQaSxsAiSwcvS33MBk3wTCVnWK+HhF8VZR2jRxehM16QcVOdHqPn4VPHmRK4lSr38n9JriurInLcP90xsYNfQ==";
      };
    };
    "is-generator-function-1.0.10" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-generator-function";
      packageName = "is-generator-function";
      version = "1.0.10";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-generator-function"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-generator-function"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-generator-function/-/is-generator-function-1.0.10.tgz";
        sha512 = "jsEjy9l3yiXEQ+PsXdmBwEPcOxaXWLspKdplFUVI9vq1iZgIekeC0L167qeu86czQaxed3q/Uzuw0swL0irL8A==";
      };
    };
    "is-negative-zero-2.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-negative-zero";
      packageName = "is-negative-zero";
      version = "2.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-negative-zero"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-negative-zero"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-negative-zero/-/is-negative-zero-2.0.2.tgz";
        sha512 = "dqJvarLawXsFbNDeJW7zAz8ItJ9cd28YufuuFzh0G8pNHjJMnY08Dv7sYX2uF5UpQOwieAeOExEYAWWfu7ZZUA==";
      };
    };
    "is-number-object-1.0.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-number-object";
      packageName = "is-number-object";
      version = "1.0.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-number-object"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-number-object"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-number-object/-/is-number-object-1.0.6.tgz";
        sha512 = "bEVOqiRcvo3zO1+G2lVMy+gkkEm9Yh7cDMRusKKu5ZJKPUYSJwICTKZrNKHA2EbSP0Tu0+6B/emsYNHZyn6K8g==";
      };
    };
    "is-regex-1.1.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-regex";
      packageName = "is-regex";
      version = "1.1.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-regex"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-regex"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-regex/-/is-regex-1.1.4.tgz";
        sha512 = "kvRdxDsxZjhzUX07ZnLydzS1TU/TJlTUHHY4YLL87e37oUA49DfkLqgy+VjFocowy29cKvcSiu+kIv728jTTVg==";
      };
    };
    "is-shared-array-buffer-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-shared-array-buffer";
      packageName = "is-shared-array-buffer";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-shared-array-buffer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-shared-array-buffer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-shared-array-buffer/-/is-shared-array-buffer-1.0.1.tgz";
        sha512 = "IU0NmyknYZN0rChcKhRO1X8LYz5Isj/Fsqh8NJOSf+N/hCOTwy29F32Ik7a+QszE63IdvmwdTPDd6cZ5pg4cwA==";
      };
    };
    "is-stream-2.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-stream";
      packageName = "is-stream";
      version = "2.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-stream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-stream/-/is-stream-2.0.1.tgz";
        sha512 = "hFoiJiTl63nn+kstHGBtewWSKnQLpyb155KHheA1l39uvtO9nWIop1p3udqPcUd/xbF1VLMO4n7OI6p7RbngDg==";
      };
    };
    "is-string-1.0.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-string";
      packageName = "is-string";
      version = "1.0.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-string"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-string"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-string/-/is-string-1.0.7.tgz";
        sha512 = "tE2UXzivje6ofPW7l23cjDOMa09gb7xlAqG6jG5ej6uPV32TlWP3NKPigtaGeHNu9fohccRYvIiZMfOOnOYUtg==";
      };
    };
    "is-symbol-1.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-symbol";
      packageName = "is-symbol";
      version = "1.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-symbol"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-symbol"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-symbol/-/is-symbol-1.0.4.tgz";
        sha512 = "C/CPBqKWnvdcxqIARxyOh4v1UUEOCHpgDa0WYgpKDFMszcrPcffg5uhwSgPCLD2WWxmq6isisz87tzT01tuGhg==";
      };
    };
    "is-typed-array-1.1.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-typed-array";
      packageName = "is-typed-array";
      version = "1.1.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-typed-array"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-typed-array"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-typed-array/-/is-typed-array-1.1.8.tgz";
        sha512 = "HqH41TNZq2fgtGT8WHVFVJhBVGuY3AnP3Q36K8JKXUxSxRgk/d+7NjmwG2vo2mYmXK8UYZKu0qH8bVP5gEisjA==";
      };
    };
    "is-weakref-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "is-weakref";
      packageName = "is-weakref";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "is-weakref"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "is-weakref"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/is-weakref/-/is-weakref-1.0.2.tgz";
        sha512 = "qctsuLZmIQ0+vSSMfoVvyFe2+GSEvnmZ2ezTup1SBse9+twCCeial6EEi3Nc2KFcf6+qz2FBPnjXsk8xhKSaPQ==";
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
    "isomorphic-ws-4.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "isomorphic-ws";
      packageName = "isomorphic-ws";
      version = "4.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "isomorphic-ws"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "isomorphic-ws"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/isomorphic-ws/-/isomorphic-ws-4.0.1.tgz";
        sha512 = "BhBvN2MBpWTaSHdWRb/bwdZJ1WaehQ2L1KngkCkfLUGF0mAWAT1sQUQacEmQ0jXkFw/czDXPNQSL5u2/Krsz1w==";
      };
    };
    "jayson-3.6.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "jayson";
      packageName = "jayson";
      version = "3.6.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "jayson"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "jayson"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/jayson/-/jayson-3.6.6.tgz";
        sha512 = "f71uvrAWTtrwoww6MKcl9phQTC+56AopLyEenWvKVAIMz+q0oVGj6tenLZ7Z6UiPBkJtKLj4kt0tACllFQruGQ==";
      };
    };
    "jmespath-0.16.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "jmespath";
      packageName = "jmespath";
      version = "0.16.0";
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
        url = "https://registry.npmjs.org/jmespath/-/jmespath-0.16.0.tgz";
        sha512 = "9FzQjJ7MATs1tSpnco1K6ayiYE3figslrXA72G2HQ/n76RzvYlofyi5QM+iX4YRs/pu3yzxlVQSST23+dMDknw==";
      };
    };
    "js-sha256-0.9.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "js-sha256";
      packageName = "js-sha256";
      version = "0.9.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "js-sha256"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "js-sha256"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/js-sha256/-/js-sha256-0.9.0.tgz";
        sha512 = "sga3MHh9sgQN2+pJ9VYZ+1LPwXOxuBJBA5nrR5/ofPfuiJBE2hnjsaN8se8JznOmGLN2p49Pe5U/ttafcs/apA==";
      };
    };
    "js-sha3-0.8.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "js-sha3";
      packageName = "js-sha3";
      version = "0.8.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "js-sha3"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "js-sha3"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/js-sha3/-/js-sha3-0.8.0.tgz";
        sha512 = "gF1cRrHhIzNfToc802P800N8PpXS+evLLXfsVpowqmAFR9uwbi89WvXg2QspOmXL8QL86J4T1EpFu+yUkwJY3Q==";
      };
    };
    "js-sha512-0.8.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "js-sha512";
      packageName = "js-sha512";
      version = "0.8.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "js-sha512"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "js-sha512"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/js-sha512/-/js-sha512-0.8.0.tgz";
        sha512 = "PWsmefG6Jkodqt+ePTvBZCSMFgN7Clckjd0O7su3I0+BW2QWUTJNzjktHsztGLhncP2h8mcF9V9Y2Ha59pAViQ==";
      };
    };
    "json-bigint-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "json-bigint";
      packageName = "json-bigint";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "json-bigint"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "json-bigint"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/json-bigint/-/json-bigint-1.0.0.tgz";
        sha512 = "SiPv/8VpZuWbvLSMtTDU8hEfrZWg/mH/nV/b4o0CYbSxu1UIQPLdwKOCIyLQX+VIPO5vrLX3i8qtqFyhdPSUSQ==";
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
    "json-stringify-safe-5.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "json-stringify-safe";
      packageName = "json-stringify-safe";
      version = "5.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "json-stringify-safe"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "json-stringify-safe"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/json-stringify-safe/-/json-stringify-safe-5.0.1.tgz";
        sha1 = "1296a2d58fd45f19a0f6ce01d65701e2c735b6eb";
      };
    };
    "jsonparse-1.3.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "jsonparse";
      packageName = "jsonparse";
      version = "1.3.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "jsonparse"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "jsonparse"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/jsonparse/-/jsonparse-1.3.1.tgz";
        sha1 = "3f4dae4a91fac315f71062f8521cc239f1366280";
      };
    };
    "keccak-3.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "keccak";
      packageName = "keccak";
      version = "3.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "keccak"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "keccak"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/keccak/-/keccak-3.0.2.tgz";
        sha512 = "PyKKjkH53wDMLGrvmRGSNWgmSxZOUqbnXwKL9tmgbFYA1iAYqW21kfR7mZXV0MlESiefxQQE9X9fTa3X+2MPDQ==";
      };
    };
    "keyv-4.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "keyv";
      packageName = "keyv";
      version = "4.1.1";
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
        url = "https://registry.npmjs.org/keyv/-/keyv-4.1.1.tgz";
        sha512 = "tGv1yP6snQVDSM4X6yxrv2zzq/EvpW+oYiUz6aueW1u9CtS8RzUQYxxmFwgZlO2jSgCxQbchhxaqXXp2hnKGpQ==";
      };
    };
    "kuler-2.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "kuler";
      packageName = "kuler";
      version = "2.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "kuler"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "kuler"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/kuler/-/kuler-2.0.0.tgz";
        sha512 = "Xq9nH7KlWZmXAtodXDDRE7vs6DU1gTU8zYDHDiWLSip45Egwq3plLHzPn27NgvzL2r1LMPC1vdqh98sQxtqj4A==";
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
    "logform-2.4.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "logform";
      packageName = "logform";
      version = "2.4.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "logform"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "logform"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/logform/-/logform-2.4.0.tgz";
        sha512 = "CPSJw4ftjf517EhXZGGvTHHkYobo7ZCc0kvwUoOYcjfR2UVrI66RHj8MCrfAdEitdmFqbu2BYdYs8FHHZSb6iw==";
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
    "lru-cache-6.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "lru-cache";
      packageName = "lru-cache";
      version = "6.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "lru-cache"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "lru-cache"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/lru-cache/-/lru-cache-6.0.0.tgz";
        sha512 = "Jo6dJ04CmSjuznwJSS3pUeWmd/H0ffTlkXXgwZi+eq1UCmqQwCh+eLsYOYCwY991i2Fah4h1BEMCx4qThGbsiA==";
      };
    };
    "make-error-1.3.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "make-error";
      packageName = "make-error";
      version = "1.3.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "make-error"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "make-error"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/make-error/-/make-error-1.3.6.tgz";
        sha512 = "s8UhlNe7vPKomQhC1qFelMokr/Sc3AgNbso3n74mVPA5LTZwkB9NlXf4XPamLxJE8h0gh73rM94xvwRT2CVInw==";
      };
    };
    "methods-1.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "methods";
      packageName = "methods";
      version = "1.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "methods"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "methods"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/methods/-/methods-1.1.2.tgz";
        sha1 = "5529a4d67654134edcc5266656835b0f851afcee";
      };
    };
    "mime-2.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "mime";
      packageName = "mime";
      version = "2.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "mime"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "mime"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/mime/-/mime-2.6.0.tgz";
        sha512 = "USPkMeET31rOMiarsBNIHZKLGgvKc/LrjofAnBlOttf5ajRvqiRA8QsenbcooctK6d6Ts6aqZXBA+XbkKthiQg==";
      };
    };
    "mime-db-1.51.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "mime-db";
      packageName = "mime-db";
      version = "1.51.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "mime-db"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "mime-db"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/mime-db/-/mime-db-1.51.0.tgz";
        sha512 = "5y8A56jg7XVQx2mbv1lu49NR4dokRnhZYTtL+KGfaa27uq4pSTXkwQkFJl4pkRMyNFz/EtYDSkiiEHx3F7UN6g==";
      };
    };
    "mime-types-2.1.34" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "mime-types";
      packageName = "mime-types";
      version = "2.1.34";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "mime-types"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "mime-types"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/mime-types/-/mime-types-2.1.34.tgz";
        sha512 = "6cP692WwGIs9XXdOO4++N+7qjqv0rqxxVvJ3VHPh/Sc9mVZcQP+ZGhkKiTvWMQRr2tbHkJP/Yn7Y0npb3ZBs4A==";
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
    "minimalistic-assert-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minimalistic-assert";
      packageName = "minimalistic-assert";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minimalistic-assert"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minimalistic-assert"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/minimalistic-assert/-/minimalistic-assert-1.0.1.tgz";
        sha512 = "UtJcAD4yEaGtjPezWuO9wC4nwUnVH/8/Im3yEHQP4b67cXlD/Qr9hdITCU1xDbSEXg2XKNaP8jsReV7vQd00/A==";
      };
    };
    "minimalistic-crypto-utils-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minimalistic-crypto-utils";
      packageName = "minimalistic-crypto-utils";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minimalistic-crypto-utils"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minimalistic-crypto-utils"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/minimalistic-crypto-utils/-/minimalistic-crypto-utils-1.0.1.tgz";
        sha1 = "f6c00c1c0b082246e5c4d99dfb8c7c083b2b582a";
      };
    };
    "minimatch-3.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "minimatch";
      packageName = "minimatch";
      version = "3.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "minimatch"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "minimatch"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/minimatch/-/minimatch-3.1.2.tgz";
        sha512 = "J7p63hRiAjw1NDEww1W7i37+ByIrOWO5XQQAzZ3VOcL0PNybwpfmV/N05zFAzwQ9USyEcX6t3UO+K5aqBQOIHw==";
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
    "ms-2.1.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ms";
      packageName = "ms";
      version = "2.1.3";
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
        url = "https://registry.npmjs.org/ms/-/ms-2.1.3.tgz";
        sha512 = "6FlzubTLZG3J2a/NVCAleEhjzq5oxgHyaCU9yYXvcLsvoVaHJq/s5xXI6/XXP6tz7R9xAOtHnSO/tXtF3WRTlA==";
      };
    };
    "multistream-4.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "multistream";
      packageName = "multistream";
      version = "4.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "multistream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "multistream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/multistream/-/multistream-4.1.0.tgz";
        sha512 = "J1XDiAmmNpRCBfIWJv+n0ymC4ABcf/Pl+5YvC5B/D2f/2+8PtHvCNxMPKiQcZyi922Hq69J2YOpb1pTywfifyw==";
      };
    };
    "noble-ed25519-1.2.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "noble-ed25519";
      packageName = "noble-ed25519";
      version = "1.2.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "noble-ed25519"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "noble-ed25519"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/noble-ed25519/-/noble-ed25519-1.2.6.tgz";
        sha512 = "zfnWqg9FVMp8CnzUpAjbt1nDXpDjCvxYiCXdnW1mY8zQHw/6twUlkFm14VPdojVzc0kcd+i9zT79+26GcNbsuQ==";
      };
    };
    "node-addon-api-2.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "node-addon-api";
      packageName = "node-addon-api";
      version = "2.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "node-addon-api"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "node-addon-api"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/node-addon-api/-/node-addon-api-2.0.2.tgz";
        sha512 = "Ntyt4AIXyaLIuMHF6IOoTakB3K+RWxwtsHNRxllEoA6vPwP9o4866g6YWDLUdnucilZhmkxiHwHr11gAENw+QA==";
      };
    };
    "node-fetch-2.6.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "node-fetch";
      packageName = "node-fetch";
      version = "2.6.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "node-fetch"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "node-fetch"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/node-fetch/-/node-fetch-2.6.7.tgz";
        sha512 = "ZjMPFEfVx5j+y2yF35Kzx5sF7kDzxuDj6ziH4FFbOp87zKDZNx8yExJIb05OGF4Nlt9IHFIMBkRl41VdvcNdbQ==";
      };
    };
    "node-gyp-build-4.3.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "node-gyp-build";
      packageName = "node-gyp-build";
      version = "4.3.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "node-gyp-build"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                if [ -f "bin/node-gyp.js" ]; then
                       substituteInPlace bin/node-gyp.js \
                         --replace 'open(output_filename' 'open(re.sub(r".*/nix/store/", "/nix/store/", output_filename)' || true
                       fi
                       if [ -f "gyp/pylib/gyp/generator/make.py" ]; then
                       substituteInPlace "gyp/pylib/gyp/generator/make.py" \
                         --replace 'open(output_filename' 'open(re.sub(r".*/nix/store/", "/nix/store/", output_filename)' || true
                       fi
                    
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "node-gyp-build"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/node-gyp-build/-/node-gyp-build-4.3.0.tgz";
        sha512 = "iWjXZvmboq0ja1pUGULQBexmxq8CV4xBhX7VDOTbL7ZR4FOowwY/VOtRxBN/yKxmdGoIp4j5ysNT4u3S2pDQ3Q==";
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
    "object-inspect-1.12.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "object-inspect";
      packageName = "object-inspect";
      version = "1.12.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "object-inspect"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "object-inspect"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/object-inspect/-/object-inspect-1.12.0.tgz";
        sha512 = "Ho2z80bVIvJloH+YzRmpZVQe87+qASmBUKZDWgx9cu+KDrX2ZDH/3tMy+gXbZETVGs2M8YdxObOh7XAtim9Y0g==";
      };
    };
    "object-keys-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "object-keys";
      packageName = "object-keys";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "object-keys"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "object-keys"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/object-keys/-/object-keys-1.1.1.tgz";
        sha512 = "NuAESUOUMrlIXOfHKzD6bpPu3tYt3xvjNdRIQ+FeT0lNb4K8WR70CaDxhuNguS2XG+GjkyMwOzsN5ZktImfhLA==";
      };
    };
    "object.assign-4.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "object.assign";
      packageName = "object.assign";
      version = "4.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "object.assign"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "object.assign"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/object.assign/-/object.assign-4.1.2.tgz";
        sha512 = "ixT2L5THXsApyiUPYKmW+2EHpXXe5Ii3M+f4e+aJFAHao5amFRW6J0OO6c/LU8Be47utCx2GL89hxGB6XSmKuQ==";
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
    "one-time-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "one-time";
      packageName = "one-time";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "one-time"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "one-time"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/one-time/-/one-time-1.0.0.tgz";
        sha512 = "5DXOiRKwuSEcQ/l0kGCF6Q3jcADFv5tSmRaJck/OqkVFcOzutB134KRSfF0xDrL39MNnqxbHBbUUcjZIhTgb2g==";
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
    "path-is-absolute-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "path-is-absolute";
      packageName = "path-is-absolute";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "path-is-absolute"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "path-is-absolute"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/path-is-absolute/-/path-is-absolute-1.0.1.tgz";
        sha1 = "174b9268735534ffbc7ace6bf53a5a9e1b5c5f5f";
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
    "pg-pool-3.5.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "pg-pool";
      packageName = "pg-pool";
      version = "3.5.1";
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
        url = "https://registry.npmjs.org/pg-pool/-/pg-pool-3.5.1.tgz";
        sha512 = "6iCR0wVrro6OOHFsyavV+i6KYL4lVNyYAB9RD18w66xSzN+d8b66HiwuP30Gp1SH5O9T82fckkzsRjlrhD0ioQ==";
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
    "process-0.11.10" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "process";
      packageName = "process";
      version = "0.11.10";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "process"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "process"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/process/-/process-0.11.10.tgz";
        sha1 = "7332300e840161bda3e69a1d1d91a7d4bc16f182";
      };
    };
    "process-nextick-args-2.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "process-nextick-args";
      packageName = "process-nextick-args";
      version = "2.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "process-nextick-args"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "process-nextick-args"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/process-nextick-args/-/process-nextick-args-2.0.1.tgz";
        sha512 = "3ouUOpQhtgrbOa17J7+uxOTpITYWaGP7/AhoR3+A+/1e9skrzelGi/dXzEYyvbxubEF6Wn2ypscTKiKJFFn1ag==";
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
    "qs-6.10.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "qs";
      packageName = "qs";
      version = "6.10.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "qs"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "qs"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/qs/-/qs-6.10.3.tgz";
        sha512 = "wr7M2E0OFRfIfJZjKGieI8lBKb7fRCH4Fv5KNPEs7gJ8jadvotdsS08PzOKR7opXhZ/Xkjtt3WF9g38drmyRqQ==";
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
    "querystringify-2.2.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "querystringify";
      packageName = "querystringify";
      version = "2.2.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "querystringify"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "querystringify"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/querystringify/-/querystringify-2.2.0.tgz";
        sha512 = "FIqgj2EUvTa7R50u0rGsyTftzjYmv/a3hO345bZNrqabNqjtgiDMgmo4mkUjd+nzU5oF3dClKqFIPUKybUyqoQ==";
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
    "readable-stream-2.3.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "readable-stream";
      packageName = "readable-stream";
      version = "2.3.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "readable-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "readable-stream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/readable-stream/-/readable-stream-2.3.7.tgz";
        sha512 = "Ebho8K4jIbHAxnuxi7o42OrZgF/ZTNcsZj6nRKyUmkhLFq8CHItp/fy6hQZuZmP/n3yZ9VBUbp4zz/mX8hmYPw==";
      };
    };
    "readable-stream-3.6.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "readable-stream";
      packageName = "readable-stream";
      version = "3.6.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "readable-stream"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "readable-stream"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/readable-stream/-/readable-stream-3.6.0.tgz";
        sha512 = "BViHy7LKeTz4oNnkcLJ+lVSL6vpiFeX6/d3oSH8zCW7UxP2onchk+vTGB143xuFjHS3deTgkKoXXymXqymiIdA==";
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
    "regenerator-runtime-0.13.9" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "regenerator-runtime";
      packageName = "regenerator-runtime";
      version = "0.13.9";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "regenerator-runtime"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "regenerator-runtime"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/regenerator-runtime/-/regenerator-runtime-0.13.9.tgz";
        sha512 = "p3VT+cOEgxFsRRA9X4lkI1E+k2/CtnKtU4gcxyaCUreilL/vqI6CdZ3wxVUx3UOUg+gnUOQQcRI7BmSI656MYA==";
      };
    };
    "requires-port-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "requires-port";
      packageName = "requires-port";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "requires-port"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "requires-port"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/requires-port/-/requires-port-1.0.0.tgz";
        sha1 = "925d2601d39ac485e091cf0da5c6e694dc3dcaff";
      };
    };
    "resolve-1.22.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "resolve";
      packageName = "resolve";
      version = "1.22.0";
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
        url = "https://registry.npmjs.org/resolve/-/resolve-1.22.0.tgz";
        sha512 = "Hhtrw0nLeSrFQ7phPp4OOcVjLPIeMnRlr5mcnVuMe7M/7eBn98A3hmFRLoFo3DLZkivSYwhRUJTyPyWAk56WLw==";
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
    "rimraf-3.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "rimraf";
      packageName = "rimraf";
      version = "3.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "rimraf"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "rimraf"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/rimraf/-/rimraf-3.0.2.tgz";
        sha512 = "JZkJMZkAGFFPP2YqXZXPbMlMBgsxzE8ILs4lMIX/2o0L9UBw9O/Y3o6wFw/i9YLapcUJWwqbi3kdxIPdC62TIA==";
      };
    };
    "rpc-websockets-7.4.17" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "rpc-websockets";
      packageName = "rpc-websockets";
      version = "7.4.17";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "rpc-websockets"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "rpc-websockets"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/rpc-websockets/-/rpc-websockets-7.4.17.tgz";
        sha512 = "eolVi/qlXS13viIUH9aqrde902wzSLAai0IjmOZSRefp5I3CSG/vCnD0c0fDSYCWuEyUoRL1BHQA8K1baEUyow==";
      };
    };
    "safe-buffer-5.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "safe-buffer";
      packageName = "safe-buffer";
      version = "5.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "safe-buffer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "safe-buffer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/safe-buffer/-/safe-buffer-5.1.2.tgz";
        sha512 = "Gd2UZBJDkXlY7GbJxfsE8/nvKkUEU1G38c1siN6QP6a9PT9MmHB8GnpscSmMJSoF8LOIrt8ud/wPtojys4G6+g==";
      };
    };
    "safe-buffer-5.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "safe-buffer";
      packageName = "safe-buffer";
      version = "5.2.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "safe-buffer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "safe-buffer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/safe-buffer/-/safe-buffer-5.2.1.tgz";
        sha512 = "rp3So07KcdmmKbGvgaNxQSJr7bGVSVk5S9Eq1F+ppbRo70+YeaDxkw5Dd8NPN+GD6bjnYm2VuPuCXmpuYvmCXQ==";
      };
    };
    "safe-stable-stringify-2.3.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "safe-stable-stringify";
      packageName = "safe-stable-stringify";
      version = "2.3.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "safe-stable-stringify"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "safe-stable-stringify"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/safe-stable-stringify/-/safe-stable-stringify-2.3.1.tgz";
        sha512 = "kYBSfT+troD9cDA85VDnHZ1rpHC50O0g1e6WlGHVCz/g+JS+9WKLj+XwFYyR8UbrZN8ll9HUpDAAddY58MGisg==";
      };
    };
    "safer-buffer-2.1.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "safer-buffer";
      packageName = "safer-buffer";
      version = "2.1.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "safer-buffer"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "safer-buffer"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/safer-buffer/-/safer-buffer-2.1.2.tgz";
        sha512 = "YZo3K82SD7Riyi0E1EQPojLz7kpepnSQI9IyPbHHg1XXXevb5dJI7tpyN2ADxGcQbHG7vcyRHk0cbwqcQriUtg==";
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
    "scrypt-js-3.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "scrypt-js";
      packageName = "scrypt-js";
      version = "3.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "scrypt-js"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "scrypt-js"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/scrypt-js/-/scrypt-js-3.0.1.tgz";
        sha512 = "cdwTTnqPu0Hyvf5in5asVdZocVDTNRmR7XEcJuIzMjJeSHybHl7vpB66AzwTaIg6CLSbtjcxc8fqcySfnTkccA==";
      };
    };
    "secp256k1-4.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "secp256k1";
      packageName = "secp256k1";
      version = "4.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "secp256k1"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "secp256k1"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/secp256k1/-/secp256k1-4.0.3.tgz";
        sha512 = "NLZVf+ROMxwtEj3Xa562qgv2BK5e2WNmXPiOdVIPLgs6lyTzMvBq0aWTYMI5XCP9jZMVKOcqZLw/Wc4vDkuxhA==";
      };
    };
    "semver-7.3.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "semver";
      packageName = "semver";
      version = "7.3.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "semver"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "semver"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/semver/-/semver-7.3.5.tgz";
        sha512 = "PoeGJYh8HK4BTO/a9Tf6ZG3veo/A7ZVsYrSA6J8ny9nb3B1VrpkuN+z9OE5wfE5p6H4LchYZsegiQgbJD94ZFQ==";
      };
    };
    "side-channel-1.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "side-channel";
      packageName = "side-channel";
      version = "1.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "side-channel"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "side-channel"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/side-channel/-/side-channel-1.0.4.tgz";
        sha512 = "q5XPytqFEIKHkGdiMIrY10mvLRvnQh42/+GoBlFW3b2LXLE2xxJpZFdm94we0BaoV3RwJyGqg5wS7epxTv0Zvw==";
      };
    };
    "simple-swizzle-0.2.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "simple-swizzle";
      packageName = "simple-swizzle";
      version = "0.2.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "simple-swizzle"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "simple-swizzle"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/simple-swizzle/-/simple-swizzle-0.2.2.tgz";
        sha1 = "a4da6b635ffcccca33f70d17cb92592de95e557a";
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
    "stack-trace-0.0.10" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "stack-trace";
      packageName = "stack-trace";
      version = "0.0.10";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "stack-trace"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "stack-trace"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/stack-trace/-/stack-trace-0.0.10.tgz";
        sha1 = "547c70b347e8d32b4e108ea1a2a159e5fdde19c0";
      };
    };
    "stream-chunker-1.2.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "stream-chunker";
      packageName = "stream-chunker";
      version = "1.2.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "stream-chunker"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "stream-chunker"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/stream-chunker/-/stream-chunker-1.2.8.tgz";
        sha1 = "eb3af2c8aee5256cde76f0a1fea86348336d04f7";
      };
    };
    "string.prototype.trimend-1.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "string.prototype.trimend";
      packageName = "string.prototype.trimend";
      version = "1.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "string.prototype.trimend"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "string.prototype.trimend"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/string.prototype.trimend/-/string.prototype.trimend-1.0.4.tgz";
        sha512 = "y9xCjw1P23Awk8EvTpcyL2NIr1j7wJ39f+k6lvRnSMz+mz9CGz9NYPelDk42kOz6+ql8xjfK8oYzy3jAP5QU5A==";
      };
    };
    "string.prototype.trimstart-1.0.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "string.prototype.trimstart";
      packageName = "string.prototype.trimstart";
      version = "1.0.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "string.prototype.trimstart"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "string.prototype.trimstart"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/string.prototype.trimstart/-/string.prototype.trimstart-1.0.4.tgz";
        sha512 = "jh6e984OBfvxS50tdY2nRZnoC5/mLFKOREQfw8t5yytkoUsJRNxvI/E39qu1sD0OtWI3OC0XgKSmcWwziwYuZw==";
      };
    };
    "string_decoder-1.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "string_decoder";
      packageName = "string_decoder";
      version = "1.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "string_decoder"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "string_decoder"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/string_decoder/-/string_decoder-1.1.1.tgz";
        sha512 = "n/ShnvDi6FHbbVfviro+WojiFzv+s8MPMHBczVePfUpDJLwoLT0ht1l4YwBCbi8pJAveEEdnkHyPyTP/mzRfwg==";
      };
    };
    "string_decoder-1.3.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "string_decoder";
      packageName = "string_decoder";
      version = "1.3.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "string_decoder"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "string_decoder"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/string_decoder/-/string_decoder-1.3.0.tgz";
        sha512 = "hkRX8U1WjJFd8LsDJ2yQ/wWWxaopEsABU1XfkM8A+j0+85JAGppt16cr1Whg6KIbb4okU6Mql6BOj+uup/wKeA==";
      };
    };
    "superagent-6.1.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "superagent";
      packageName = "superagent";
      version = "6.1.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "superagent"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "superagent"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/superagent/-/superagent-6.1.0.tgz";
        sha512 = "OUDHEssirmplo3F+1HWKUrUjvnQuA+nZI6i/JJBdXb5eq9IyEQwPyPpqND+SSsxf6TygpBEkUjISVRN4/VOpeg==";
      };
    };
    "superstruct-0.14.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "superstruct";
      packageName = "superstruct";
      version = "0.14.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "superstruct"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "superstruct"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/superstruct/-/superstruct-0.14.2.tgz";
        sha512 = "nPewA6m9mR3d6k7WkZ8N8zpTWfenFH3q9pA2PkuiZxINr9DKB2+40wEQf0ixn8VaGuJ78AB6iWOtStI+/4FKZQ==";
      };
    };
    "supports-preserve-symlinks-flag-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "supports-preserve-symlinks-flag";
      packageName = "supports-preserve-symlinks-flag";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "supports-preserve-symlinks-flag"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "supports-preserve-symlinks-flag"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/supports-preserve-symlinks-flag/-/supports-preserve-symlinks-flag-1.0.0.tgz";
        sha512 = "ot0WnXS9fgdkgIcePe6RHNk1WA8+muPa6cSjeR3V8K27q9BB1rTE3R1p7Hv0z1ZyAc8s6Vvv8DIyWf681MAt0w==";
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
    "text-encoding-utf-8-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "text-encoding-utf-8";
      packageName = "text-encoding-utf-8";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "text-encoding-utf-8"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "text-encoding-utf-8"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/text-encoding-utf-8/-/text-encoding-utf-8-1.0.2.tgz";
        sha512 = "8bw4MY9WjdsD2aMtO0OzOCY3pXGYNx2d2FfHRVUKkiCPDWjKuOlhLVASS+pD7VkLTVjW268LYJHwsnPFlBpbAg==";
      };
    };
    "text-hex-1.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "text-hex";
      packageName = "text-hex";
      version = "1.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "text-hex"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "text-hex"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/text-hex/-/text-hex-1.0.0.tgz";
        sha512 = "uuVGNWzgJ4yhRaNSiubPY7OjISw4sw4E5Uv0wbjp+OzcbmVU/rsT8ujgcXJhn9ypzsgr5vlzpPqP+MBBKcGvbg==";
      };
    };
    "through-2.3.8" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "through";
      packageName = "through";
      version = "2.3.8";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "through"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "through"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/through/-/through-2.3.8.tgz";
        sha1 = "0dd4c9ffaabc357960b1b724115d7e0e86a2e1f5";
      };
    };
    "through2-2.0.5" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "through2";
      packageName = "through2";
      version = "2.0.5";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "through2"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "through2"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/through2/-/through2-2.0.5.tgz";
        sha512 = "/mrRod8xqpA+IHSLyGCQ2s8SPHiCDEeQJSep1jqLYeEUClOFG2Qsh+4FU6G9VeqpZnGW/Su8LQGc4YKni5rYSQ==";
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
    "tmp-0.2.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "tmp";
      packageName = "tmp";
      version = "0.2.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "tmp"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "tmp"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/tmp/-/tmp-0.2.1.tgz";
        sha512 = "76SUhtfqR2Ijn+xllcI5P1oyannHNHByD80W1q447gU3mp9G9PSpGdWmjUOHRDPiHYacIk66W7ubDTuPF3BEtQ==";
      };
    };
    "tmp-promise-3.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "tmp-promise";
      packageName = "tmp-promise";
      version = "3.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "tmp-promise"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "tmp-promise"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/tmp-promise/-/tmp-promise-3.0.3.tgz";
        sha512 = "RwM7MoPojPxsOBYnyd2hy0bxtIlVrihNs9pj5SUvY8Zz1sQcQG2tG1hSr8PDxfgEB8RNKDhqbIlroIarSNDNsQ==";
      };
    };
    "tr46-0.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "tr46";
      packageName = "tr46";
      version = "0.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "tr46"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "tr46"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/tr46/-/tr46-0.0.3.tgz";
        sha1 = "8184fd347dac9cdc185992f3a6622e14b9d9ab6a";
      };
    };
    "triple-beam-1.3.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "triple-beam";
      packageName = "triple-beam";
      version = "1.3.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "triple-beam"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "triple-beam"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/triple-beam/-/triple-beam-1.3.0.tgz";
        sha512 = "XrHUvV5HpdLmIj4uVMxHggLbFSZYIn7HEWsqePZcI50pco+MPqJ50wMGY794X7AOOhxOBAjbkqfAbEe/QMp2Lw==";
      };
    };
    "ts-node-10.7.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ts-node";
      packageName = "ts-node";
      version = "10.7.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ts-node"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ts-node"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/ts-node/-/ts-node-10.7.0.tgz";
        sha512 = "TbIGS4xgJoX2i3do417KSaep1uRAW/Lu+WAL2doDHC0D6ummjirVOXU5/7aiZotbQ5p1Zp9tP7U6cYhA0O7M8A==";
      };
    };
    "tslib-2.3.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "tslib";
      packageName = "tslib";
      version = "2.3.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "tslib"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "tslib"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/tslib/-/tslib-2.3.1.tgz";
        sha512 = "77EbyPPpMz+FRFRuAFlWMtmgUWGe9UOG2Z25NqCwiIjRhOf5iKGuzSe5P2w1laq+FkRy4p+PCuVkJSGkzTEKVw==";
      };
    };
    "tweetnacl-1.0.3" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "tweetnacl";
      packageName = "tweetnacl";
      version = "1.0.3";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "tweetnacl"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "tweetnacl"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/tweetnacl/-/tweetnacl-1.0.3.tgz";
        sha512 = "6rt+RN7aOi1nGMyC4Xa5DdYiukl2UWCbcJft7YhxReBGQD7OAM8Pbxw6YMo4r2diNEA8FEmu32YOn9rhaiE5yw==";
      };
    };
    "unbox-primitive-1.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "unbox-primitive";
      packageName = "unbox-primitive";
      version = "1.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "unbox-primitive"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "unbox-primitive"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/unbox-primitive/-/unbox-primitive-1.0.1.tgz";
        sha512 = "tZU/3NqK3dA5gpE1KtyiJUrEB0lxnGkMFHptJ7q6ewdZ8s12QrODwNbhIJStmJkd1QDXa1NRA8aF2A1zk/Ypyw==";
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
    "url-parse-1.5.10" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "url-parse";
      packageName = "url-parse";
      version = "1.5.10";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "url-parse"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "url-parse"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/url-parse/-/url-parse-1.5.10.tgz";
        sha512 = "WypcfiRhfeUP9vvF0j6rw0J3hrWrw6iZv3+22h6iRMJ/8z1Tj6XfLP4DsUix5MhMPnXpiHDoKyoZ/bdCkwBCiQ==";
      };
    };
    "util-0.12.4" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "util";
      packageName = "util";
      version = "0.12.4";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "util"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "util"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/util/-/util-0.12.4.tgz";
        sha512 = "bxZ9qtSlGUWSOy9Qa9Xgk11kSslpuZwaxCg4sNIDj6FLucDab2JxnHwyNTCpHMtK1MjoQiWQ6DiUMZYbSrO+Sw==";
      };
    };
    "util-deprecate-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "util-deprecate";
      packageName = "util-deprecate";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "util-deprecate"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "util-deprecate"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/util-deprecate/-/util-deprecate-1.0.2.tgz";
        sha1 = "450d4dc9fa70de732762fbd2d4a28981419a0ccf";
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
    "uuid-8.3.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "uuid";
      packageName = "uuid";
      version = "8.3.2";
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
        url = "https://registry.npmjs.org/uuid/-/uuid-8.3.2.tgz";
        sha512 = "+NYs2QeMWy+GWFOEm9xnn6HCDp0l7QBD7ml8zLUmJ+93Q5NF0NocErnwkTkXVFNiX3/fpC6afS8Dhb/gz7R7eg==";
      };
    };
    "v8-compile-cache-lib-3.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "v8-compile-cache-lib";
      packageName = "v8-compile-cache-lib";
      version = "3.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "v8-compile-cache-lib"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "v8-compile-cache-lib"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/v8-compile-cache-lib/-/v8-compile-cache-lib-3.0.0.tgz";
        sha512 = "mpSYqfsFvASnSn5qMiwrr4VKfumbPyONLCOPmsR3A6pTY/r0+tSaVbgPWSAIuzbk3lCTa+FForeTiO+wBQGkjA==";
      };
    };
    "webidl-conversions-3.0.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "webidl-conversions";
      packageName = "webidl-conversions";
      version = "3.0.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "webidl-conversions"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "webidl-conversions"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/webidl-conversions/-/webidl-conversions-3.0.1.tgz";
        sha1 = "24534275e2a7bc6be7bc86611cc16ae0a5654871";
      };
    };
    "whatwg-url-5.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "whatwg-url";
      packageName = "whatwg-url";
      version = "5.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "whatwg-url"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "whatwg-url"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/whatwg-url/-/whatwg-url-5.0.0.tgz";
        sha1 = "966454e8765462e37644d3626f6742ce8b70965d";
      };
    };
    "which-boxed-primitive-1.0.2" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "which-boxed-primitive";
      packageName = "which-boxed-primitive";
      version = "1.0.2";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "which-boxed-primitive"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "which-boxed-primitive"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/which-boxed-primitive/-/which-boxed-primitive-1.0.2.tgz";
        sha512 = "bwZdv0AKLpplFY2KZRX6TvyuN7ojjr7lwkg6ml0roIy9YeuSr7JS372qlNW18UQYzgYK9ziGcerWqZOmEn9VNg==";
      };
    };
    "which-typed-array-1.1.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "which-typed-array";
      packageName = "which-typed-array";
      version = "1.1.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "which-typed-array"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "which-typed-array"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/which-typed-array/-/which-typed-array-1.1.7.tgz";
        sha512 = "vjxaB4nfDqwKI0ws7wZpxIlde1XrLX5uB0ZjpfshgmapJMD7jJWhZI+yToJTqaFByF0eNBcYxbjmCzoRP7CfEw==";
      };
    };
    "winston-transport-4.5.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "winston-transport";
      packageName = "winston-transport";
      version = "4.5.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "winston-transport"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "winston-transport"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/winston-transport/-/winston-transport-4.5.0.tgz";
        sha512 = "YpZzcUzBedhlTAfJg6vJDlyEai/IFMIVcaEZZyl3UXIl4gmqRpU7AE89AHLkbzLUsv0NVmw7ts+iztqKxxPW1Q==";
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
    "ws-7.4.6" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ws";
      packageName = "ws";
      version = "7.4.6";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ws"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ws"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/ws/-/ws-7.4.6.tgz";
        sha512 = "YmhHDO4MzaDLB+M9ym/mDA5z0naX8j7SIlT8f8z+I0VtzsRbekxEutHSme7NPS2qE8StCYQNUnfWdXta/Yu85A==";
      };
    };
    "ws-7.5.7" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "ws";
      packageName = "ws";
      version = "7.5.7";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "ws"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "ws"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/ws/-/ws-7.5.7.tgz";
        sha512 = "KMvVuFzpKBuiIXW3E4u3mySRO2/mCHSyZDJQM5NQ9Q9KHWHWh0NHgfbRMLLrceUK5qAL4ytALJbpRMjixFZh8A==";
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
    "yallist-4.0.0" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "yallist";
      packageName = "yallist";
      version = "4.0.0";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "yallist"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "yallist"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/yallist/-/yallist-4.0.0.tgz";
        sha512 = "3wdGidZyq5PB084XLES5TpOSRA3wjXAlIWMhum2kRcv/41Sn2emQ0dycQW4uZXLejwKvg6EsvbdlVL+FYEct7A==";
      };
    };
    "yn-3.1.1" = {dependencies ? []}:

    stdenv.mkDerivation {
      name = "yn";
      packageName = "yn";
      version = "3.1.1";
      extraDependencies = [];
      buildInputs = [
        jq
        nodejs
      ];
      NODE_OPTIONS = "--preserve-symlinks";
      unpackPhase = transitiveDepUnpackPhase { inherit dependencies; pkgName = "yn"; } + '''';
      patchPhase = ''
                if [ -f "package.json" ]; then
                  cat <<< $(jq 'del(.scripts)' package.json) > package.json
                fi
                
              '';
      configurePhase = "true";
      buildPhase = "true";
      fixupPhase = "true";
      installPhase = transitiveDepInstallPhase { inherit dependencies; pkgName = "yn"; };
      doCheck = false;
      doInstallCheck = false;
      src = fetchurl {
        url = "https://registry.npmjs.org/yn/-/yn-3.1.1.tgz";
        sha512 = "Ux4ygGWsu2c7isFWe8Yu1YluJmqVhxqK2cLXNQA5AcC3QfbGNpM7fu0Y8b/z16pXLnFxZYvWhd3fhBY9DLmC6Q==";
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
    arbundles = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "arbundles"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "arbundles";
      packageName = "arbundles";
      version = "0.6.16";
      src = fetchurl {
        url = "https://registry.npmjs.org/arbundles/-/arbundles-0.6.16.tgz";
        sha512 = "c5IwwHTSE2SNi+/Zd/BqK3ci3367AqACVnuV1u04NoEZ+czD02MtmgTzQ35wxSR+P6oeYNp5+nL4XwxlMtljiQ==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "arbundles"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "arbundles"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "arbundles"; };
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
      installScript = mkInstallScript { pkgName = "arbundles"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "arbundles"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "arbundles"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "arbundles"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "arbundles"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "arbundles"; });
      meta = {
        description = "Arweave bundling library";
        license = "Apache-2.0";
        homepage = "";
      };
    };
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
      version = "2.1082.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/aws-sdk/-/aws-sdk-2.1082.0.tgz";
        sha512 = "aDrUZ63O/ocuC827ursDqFQAm3jhqsJu1DvMCCFg73y+FK9pXXNHp2mwdi3UeeHvtfxISCLCjuyO3VFd/tpVfA==";
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
      version = "12.0.1";
      src = fetchurl {
        url = "https://registry.npmjs.org/got/-/got-12.0.1.tgz";
        sha512 = "1Zhoh+lDej3t7Ks1BP/Jufn+rNqdiHQgUOcTxHzg2Dao1LQfp5S4Iq0T3iBxN4Zdo7QqCJL+WJUNzDX6rCP2Ew==";
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
      version = "8.7.3";
      src = fetchurl {
        url = "https://registry.npmjs.org/pg/-/pg-8.7.3.tgz";
        sha512 = "HPmH4GH4H3AOprDJOazoIcpI49XFsHCe8xlrjHkWiapdbHK+HLtbm/GQzXYAZwmPju/kzKhjaSfMACG+8cgJcw==";
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
      version = "0.27.2";
      src = fetchurl {
        url = "https://registry.npmjs.org/ramda/-/ramda-0.27.2.tgz";
        sha512 = "SbiLPU40JuJniHexQSAgad32hfwd+DRUdwF2PlVuI5RZD0/vahUco7R8vD86J/tcEKKF9vZrUVwgtmGCqlCKyA==";
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
    winston = let
      dependencies = [];
      extraDependencies = [] ++
            mkExtraDependencies
             (pkgs // { inherit jsnixDeps dependencies; })
             { pkgName = "winston"; };
    in
    stdenv.mkDerivation {
      inherit dependencies extraDependencies;
      name = "winston";
      packageName = "winston";
      version = "3.6.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/winston/-/winston-3.6.0.tgz";
        sha512 = "9j8T75p+bcN6D00sF/zjFVmPp+t8KMPB1MzbbzYjeN9VWxdsYnTB40TkbNUEXAmILEfChMvAMgidlX64OG3p6w==";
      };
      buildInputs = [ nodejs python3 makeWrapper jq  ] ++
         (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xcodebuild ]) ++
         (mkExtraBuildInputs (pkgs // { inherit jsnixDeps dependencies; }) { pkgName = "winston"; });
      doFixup = false;
      doStrip = false;
      NODE_OPTIONS = "--preserve-symlinks";
      passAsFile = [ "unpackScript" "buildScript" "installScript" ];
      unpackScript = mkUnpackScript { dependencies = dependencies ++ extraDependencies;
         pkgName = "winston"; };
      buildScript = mkBuildScript { inherit dependencies; pkgName = "winston"; };
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
      installScript = mkInstallScript { pkgName = "winston"; };
      installPhase = ''
      if [ -z "$preInstall" ]; then
        runHook preInstall
      fi
      source $installScriptPath
      if [ -z "$postInstall" ]; then
        runHook postInstall
      fi
    '';
      preInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preInstall"; pkgName = "winston"; });
      postInstall = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postInstall"; pkgName = "winston"; });
      preBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "preBuild"; pkgName = "winston"; });
      postBuild = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "postBuild"; pkgName = "winston"; });
      fixupPhase = "true";
      installCheckPhase = (mkPhase (pkgs // { inherit jsnixDeps nodejs dependencies; }) { phase = "installCheckPhase"; pkgName = "winston"; });
      meta = {
        description = "A logger for just about everything.";
        license = "MIT";
        homepage = "https://github.com/winstonjs/winston#readme";
      };
    };
  };
  dedupedDeps = {
    "@babel/runtime" = sources."@babel/runtime-7.17.2" {
      dependencies = [];
    };
    "@cspotcode/source-map-consumer" = sources."@cspotcode/source-map-consumer-0.8.0" {
      dependencies = [];
    };
    "@cspotcode/source-map-support" = sources."@cspotcode/source-map-support-0.7.0" {
      dependencies = [];
    };
    "@ethersproject/abi" = sources."@ethersproject/abi-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/abstract-provider" = sources."@ethersproject/abstract-provider-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/abstract-signer" = sources."@ethersproject/abstract-signer-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/address" = sources."@ethersproject/address-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/base64" = sources."@ethersproject/base64-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/basex" = sources."@ethersproject/basex-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/bignumber" = sources."@ethersproject/bignumber-5.6.0" {
      dependencies = [
        (sources."bn.js-4.12.0" {
          dependencies = [];
        })
      ];
    };
    "@ethersproject/bytes" = sources."@ethersproject/bytes-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/constants" = sources."@ethersproject/constants-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/contracts" = sources."@ethersproject/contracts-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/hash" = sources."@ethersproject/hash-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/hdnode" = sources."@ethersproject/hdnode-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/json-wallets" = sources."@ethersproject/json-wallets-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/keccak256" = sources."@ethersproject/keccak256-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/logger" = sources."@ethersproject/logger-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/networks" = sources."@ethersproject/networks-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/pbkdf2" = sources."@ethersproject/pbkdf2-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/properties" = sources."@ethersproject/properties-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/providers" = sources."@ethersproject/providers-5.6.1" {
      dependencies = [
        (sources."ws-7.4.6" {
          dependencies = [];
        })
      ];
    };
    "@ethersproject/random" = sources."@ethersproject/random-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/rlp" = sources."@ethersproject/rlp-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/sha2" = sources."@ethersproject/sha2-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/signing-key" = sources."@ethersproject/signing-key-5.6.0" {
      dependencies = [
        (sources."bn.js-4.12.0" {
          dependencies = [];
        })
      ];
    };
    "@ethersproject/solidity" = sources."@ethersproject/solidity-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/strings" = sources."@ethersproject/strings-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/transactions" = sources."@ethersproject/transactions-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/units" = sources."@ethersproject/units-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/wallet" = sources."@ethersproject/wallet-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/web" = sources."@ethersproject/web-5.6.0" {
      dependencies = [];
    };
    "@ethersproject/wordlists" = sources."@ethersproject/wordlists-5.6.0" {
      dependencies = [];
    };
    "@randlabs/communication-bridge" = sources."@randlabs/communication-bridge-1.0.0" {
      dependencies = [];
    };
    "@randlabs/myalgo-connect" = sources."@randlabs/myalgo-connect-1.1.2" {
      dependencies = [];
    };
    "@solana/buffer-layout" = sources."@solana/buffer-layout-3.0.0" {
      dependencies = [
        (sources."buffer-6.0.3" {
          dependencies = [];
        })
      ];
    };
    "@solana/wallet-adapter-base" = sources."@solana/wallet-adapter-base-0.9.5" {
      dependencies = [];
    };
    "@solana/web3.js" = sources."@solana/web3.js-1.36.0" {
      dependencies = [];
    };
    "@tsconfig/node10" = sources."@tsconfig/node10-1.0.8" {
      dependencies = [];
    };
    "@tsconfig/node12" = sources."@tsconfig/node12-1.0.9" {
      dependencies = [];
    };
    "@tsconfig/node14" = sources."@tsconfig/node14-1.0.1" {
      dependencies = [];
    };
    "@tsconfig/node16" = sources."@tsconfig/node16-1.0.2" {
      dependencies = [];
    };
    "@types/axios" = sources."@types/axios-0.14.0" {
      dependencies = [];
    };
    "@types/bn.js" = sources."@types/bn.js-4.11.6" {
      dependencies = [];
    };
    "@types/bs58" = sources."@types/bs58-4.0.1" {
      dependencies = [];
    };
    "@types/connect" = sources."@types/connect-3.4.35" {
      dependencies = [];
    };
    "@types/express-serve-static-core" = sources."@types/express-serve-static-core-4.17.28" {
      dependencies = [];
    };
    "@types/lodash" = sources."@types/lodash-4.14.179" {
      dependencies = [];
    };
    "@types/multistream" = sources."@types/multistream-2.1.2" {
      dependencies = [];
    };
    "@types/node" = sources."@types/node-17.0.21" {
      dependencies = [];
    };
    "@types/qs" = sources."@types/qs-6.9.7" {
      dependencies = [];
    };
    "@types/range-parser" = sources."@types/range-parser-1.2.4" {
      dependencies = [];
    };
    "@types/secp256k1" = sources."@types/secp256k1-4.0.3" {
      dependencies = [];
    };
    "@types/ws" = sources."@types/ws-7.4.7" {
      dependencies = [];
    };
    JSONStream = sources."JSONStream-1.3.5" {
      dependencies = [];
    };
    acorn = sources."acorn-8.7.0" {
      dependencies = [];
    };
    acorn-walk = sources."acorn-walk-8.2.0" {
      dependencies = [];
    };
    aes-js = sources."aes-js-3.0.0" {
      dependencies = [];
    };
    algo-msgpack-with-bigint = sources."algo-msgpack-with-bigint-2.1.1" {
      dependencies = [];
    };
    algosdk = sources."algosdk-1.14.0" {
      dependencies = [
        (sources."buffer-6.0.3" {
          dependencies = [];
        })
      ];
    };
    arconnect = sources."arconnect-0.2.9" {
      dependencies = [];
    };
    arg = sources."arg-4.1.3" {
      dependencies = [];
    };
    arweave = sources."arweave-1.10.23" {
      dependencies = [
        (sources."axios-0.22.0" {
          dependencies = [];
        })
      ];
    };
    arweave-stream-tx = sources."arweave-stream-tx-1.1.0" {
      dependencies = [];
    };
    "asn1.js" = sources."asn1.js-5.4.1" {
      dependencies = [
        (sources."bn.js-4.12.0" {
          dependencies = [];
        })
      ];
    };
    asynckit = sources."asynckit-0.4.0" {
      dependencies = [];
    };
    available-typed-arrays = sources."available-typed-arrays-1.0.5" {
      dependencies = [];
    };
    avsc = sources."avsc-5.7.3" {
      dependencies = [];
    };
    axios = sources."axios-0.21.4" {
      dependencies = [];
    };
    balanced-match = sources."balanced-match-1.0.2" {
      dependencies = [];
    };
    base-x = sources."base-x-3.0.9" {
      dependencies = [];
    };
    base64url = sources."base64url-3.0.1" {
      dependencies = [];
    };
    bech32 = sources."bech32-1.1.4" {
      dependencies = [];
    };
    "bignumber.js" = sources."bignumber.js-9.0.2" {
      dependencies = [];
    };
    "bn.js" = sources."bn.js-5.2.0" {
      dependencies = [];
    };
    borsh = sources."borsh-0.4.0" {
      dependencies = [];
    };
    brace-expansion = sources."brace-expansion-1.1.11" {
      dependencies = [];
    };
    brorand = sources."brorand-1.1.0" {
      dependencies = [];
    };
    bs58 = sources."bs58-4.0.1" {
      dependencies = [];
    };
    call-bind = sources."call-bind-1.0.2" {
      dependencies = [];
    };
    circular-json = sources."circular-json-0.5.9" {
      dependencies = [];
    };
    combined-stream = sources."combined-stream-1.0.8" {
      dependencies = [];
    };
    commander = sources."commander-2.20.3" {
      dependencies = [];
    };
    component-emitter = sources."component-emitter-1.3.0" {
      dependencies = [];
    };
    concat-map = sources."concat-map-0.0.1" {
      dependencies = [];
    };
    cookiejar = sources."cookiejar-2.1.3" {
      dependencies = [];
    };
    core-util-is = sources."core-util-is-1.0.3" {
      dependencies = [];
    };
    create-require = sources."create-require-1.1.1" {
      dependencies = [];
    };
    cross-fetch = sources."cross-fetch-3.1.5" {
      dependencies = [];
    };
    define-properties = sources."define-properties-1.1.3" {
      dependencies = [];
    };
    delay = sources."delay-5.0.0" {
      dependencies = [];
    };
    delayed-stream = sources."delayed-stream-1.0.0" {
      dependencies = [];
    };
    diff = sources."diff-4.0.2" {
      dependencies = [];
    };
    elliptic = sources."elliptic-6.5.4" {
      dependencies = [
        (sources."bn.js-4.12.0" {
          dependencies = [];
        })
      ];
    };
    es-abstract = sources."es-abstract-1.19.1" {
      dependencies = [];
    };
    es-to-primitive = sources."es-to-primitive-1.2.1" {
      dependencies = [];
    };
    es6-promise = sources."es6-promise-4.2.8" {
      dependencies = [];
    };
    es6-promisify = sources."es6-promisify-5.0.0" {
      dependencies = [];
    };
    ethers = sources."ethers-5.6.1" {
      dependencies = [];
    };
    eventemitter3 = sources."eventemitter3-4.0.7" {
      dependencies = [];
    };
    exponential-backoff = sources."exponential-backoff-3.1.0" {
      dependencies = [];
    };
    eyes = sources."eyes-0.1.8" {
      dependencies = [];
    };
    fast-safe-stringify = sources."fast-safe-stringify-2.1.1" {
      dependencies = [];
    };
    follow-redirects = sources."follow-redirects-1.14.9" {
      dependencies = [];
    };
    foreach = sources."foreach-2.0.5" {
      dependencies = [];
    };
    form-data = sources."form-data-3.0.1" {
      dependencies = [];
    };
    formidable = sources."formidable-1.2.6" {
      dependencies = [];
    };
    "fs.realpath" = sources."fs.realpath-1.0.0" {
      dependencies = [];
    };
    function-bind = sources."function-bind-1.1.1" {
      dependencies = [];
    };
    get-intrinsic = sources."get-intrinsic-1.1.1" {
      dependencies = [];
    };
    get-symbol-description = sources."get-symbol-description-1.0.0" {
      dependencies = [];
    };
    glob = sources."glob-7.2.0" {
      dependencies = [];
    };
    has = sources."has-1.0.3" {
      dependencies = [];
    };
    has-bigints = sources."has-bigints-1.0.1" {
      dependencies = [];
    };
    has-symbols = sources."has-symbols-1.0.2" {
      dependencies = [];
    };
    has-tostringtag = sources."has-tostringtag-1.0.0" {
      dependencies = [];
    };
    "hash.js" = sources."hash.js-1.1.7" {
      dependencies = [];
    };
    hi-base32 = sources."hi-base32-0.5.1" {
      dependencies = [];
    };
    hmac-drbg = sources."hmac-drbg-1.0.1" {
      dependencies = [];
    };
    inflight = sources."inflight-1.0.6" {
      dependencies = [];
    };
    inherits = sources."inherits-2.0.4" {
      dependencies = [];
    };
    internal-slot = sources."internal-slot-1.0.3" {
      dependencies = [];
    };
    is-arguments = sources."is-arguments-1.1.1" {
      dependencies = [];
    };
    is-bigint = sources."is-bigint-1.0.4" {
      dependencies = [];
    };
    is-boolean-object = sources."is-boolean-object-1.1.2" {
      dependencies = [];
    };
    is-callable = sources."is-callable-1.2.4" {
      dependencies = [];
    };
    is-date-object = sources."is-date-object-1.0.5" {
      dependencies = [];
    };
    is-generator-function = sources."is-generator-function-1.0.10" {
      dependencies = [];
    };
    is-negative-zero = sources."is-negative-zero-2.0.2" {
      dependencies = [];
    };
    is-number-object = sources."is-number-object-1.0.6" {
      dependencies = [];
    };
    is-regex = sources."is-regex-1.1.4" {
      dependencies = [];
    };
    is-shared-array-buffer = sources."is-shared-array-buffer-1.0.1" {
      dependencies = [];
    };
    is-string = sources."is-string-1.0.7" {
      dependencies = [];
    };
    is-symbol = sources."is-symbol-1.0.4" {
      dependencies = [];
    };
    is-typed-array = sources."is-typed-array-1.1.8" {
      dependencies = [];
    };
    is-weakref = sources."is-weakref-1.0.2" {
      dependencies = [];
    };
    isomorphic-ws = sources."isomorphic-ws-4.0.1" {
      dependencies = [];
    };
    jayson = sources."jayson-3.6.6" {
      dependencies = [
        (sources."@types/node-12.20.46" {
          dependencies = [];
        })
      ];
    };
    js-sha256 = sources."js-sha256-0.9.0" {
      dependencies = [];
    };
    js-sha3 = sources."js-sha3-0.8.0" {
      dependencies = [];
    };
    js-sha512 = sources."js-sha512-0.8.0" {
      dependencies = [];
    };
    json-bigint = sources."json-bigint-1.0.0" {
      dependencies = [];
    };
    json-stringify-safe = sources."json-stringify-safe-5.0.1" {
      dependencies = [];
    };
    jsonparse = sources."jsonparse-1.3.1" {
      dependencies = [];
    };
    keccak = sources."keccak-3.0.2" {
      dependencies = [];
    };
    lodash = sources."lodash-4.17.21" {
      dependencies = [];
    };
    lru-cache = sources."lru-cache-6.0.0" {
      dependencies = [];
    };
    make-error = sources."make-error-1.3.6" {
      dependencies = [];
    };
    methods = sources."methods-1.1.2" {
      dependencies = [];
    };
    mime = sources."mime-2.6.0" {
      dependencies = [];
    };
    mime-db = sources."mime-db-1.51.0" {
      dependencies = [];
    };
    mime-types = sources."mime-types-2.1.34" {
      dependencies = [];
    };
    minimalistic-assert = sources."minimalistic-assert-1.0.1" {
      dependencies = [];
    };
    minimalistic-crypto-utils = sources."minimalistic-crypto-utils-1.0.1" {
      dependencies = [];
    };
    minimatch = sources."minimatch-3.1.2" {
      dependencies = [];
    };
    ms = sources."ms-2.1.2" {
      dependencies = [];
    };
    multistream = sources."multistream-4.1.0" {
      dependencies = [];
    };
    noble-ed25519 = sources."noble-ed25519-1.2.6" {
      dependencies = [];
    };
    node-addon-api = sources."node-addon-api-2.0.2" {
      dependencies = [];
    };
    node-fetch = sources."node-fetch-2.6.7" {
      dependencies = [];
    };
    node-gyp-build = sources."node-gyp-build-4.3.0" {
      dependencies = [];
    };
    object-inspect = sources."object-inspect-1.12.0" {
      dependencies = [];
    };
    object-keys = sources."object-keys-1.1.1" {
      dependencies = [];
    };
    "object.assign" = sources."object.assign-4.1.2" {
      dependencies = [];
    };
    path-is-absolute = sources."path-is-absolute-1.0.1" {
      dependencies = [];
    };
    process = sources."process-0.11.10" {
      dependencies = [];
    };
    process-nextick-args = sources."process-nextick-args-2.0.1" {
      dependencies = [];
    };
    qs = sources."qs-6.10.3" {
      dependencies = [];
    };
    querystringify = sources."querystringify-2.2.0" {
      dependencies = [];
    };
    regenerator-runtime = sources."regenerator-runtime-0.13.9" {
      dependencies = [];
    };
    requires-port = sources."requires-port-1.0.0" {
      dependencies = [];
    };
    rimraf = sources."rimraf-3.0.2" {
      dependencies = [];
    };
    rpc-websockets = sources."rpc-websockets-7.4.17" {
      dependencies = [];
    };
    safe-buffer = sources."safe-buffer-5.2.1" {
      dependencies = [];
    };
    safer-buffer = sources."safer-buffer-2.1.2" {
      dependencies = [];
    };
    scrypt-js = sources."scrypt-js-3.0.1" {
      dependencies = [];
    };
    secp256k1 = sources."secp256k1-4.0.3" {
      dependencies = [];
    };
    semver = sources."semver-7.3.5" {
      dependencies = [];
    };
    side-channel = sources."side-channel-1.0.4" {
      dependencies = [];
    };
    stream-chunker = sources."stream-chunker-1.2.8" {
      dependencies = [];
    };
    "string.prototype.trimend" = sources."string.prototype.trimend-1.0.4" {
      dependencies = [];
    };
    "string.prototype.trimstart" = sources."string.prototype.trimstart-1.0.4" {
      dependencies = [];
    };
    string_decoder = sources."string_decoder-1.3.0" {
      dependencies = [];
    };
    superagent = sources."superagent-6.1.0" {
      dependencies = [];
    };
    superstruct = sources."superstruct-0.14.2" {
      dependencies = [];
    };
    text-encoding-utf-8 = sources."text-encoding-utf-8-1.0.2" {
      dependencies = [];
    };
    through = sources."through-2.3.8" {
      dependencies = [];
    };
    through2 = sources."through2-2.0.5" {
      dependencies = [
        (sources."readable-stream-2.3.7" {
          dependencies = [];
        })
        (sources."safe-buffer-5.1.2" {
          dependencies = [];
        })
        (sources."string_decoder-1.1.1" {
          dependencies = [];
        })
      ];
    };
    tmp = sources."tmp-0.2.1" {
      dependencies = [];
    };
    tmp-promise = sources."tmp-promise-3.0.3" {
      dependencies = [];
    };
    tr46 = sources."tr46-0.0.3" {
      dependencies = [];
    };
    ts-node = sources."ts-node-10.7.0" {
      dependencies = [];
    };
    tslib = sources."tslib-2.3.1" {
      dependencies = [];
    };
    tweetnacl = sources."tweetnacl-1.0.3" {
      dependencies = [];
    };
    unbox-primitive = sources."unbox-primitive-1.0.1" {
      dependencies = [];
    };
    url-parse = sources."url-parse-1.5.10" {
      dependencies = [];
    };
    util = sources."util-0.12.4" {
      dependencies = [];
    };
    util-deprecate = sources."util-deprecate-1.0.2" {
      dependencies = [];
    };
    v8-compile-cache-lib = sources."v8-compile-cache-lib-3.0.0" {
      dependencies = [];
    };
    webidl-conversions = sources."webidl-conversions-3.0.1" {
      dependencies = [];
    };
    whatwg-url = sources."whatwg-url-5.0.0" {
      dependencies = [];
    };
    which-boxed-primitive = sources."which-boxed-primitive-1.0.2" {
      dependencies = [];
    };
    which-typed-array = sources."which-typed-array-1.1.7" {
      dependencies = [];
    };
    wrappy = sources."wrappy-1.0.2" {
      dependencies = [];
    };
    ws = sources."ws-7.5.7" {
      dependencies = [];
    };
    yallist = sources."yallist-4.0.0" {
      dependencies = [];
    };
    yn = sources."yn-3.1.1" {
      dependencies = [];
    };
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
    jmespath = sources."jmespath-0.16.0" {
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
    "@sindresorhus/is" = sources."@sindresorhus/is-4.6.0" {
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
    keyv = sources."keyv-4.1.1" {
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
    colorette = sources."colorette-2.0.16" {
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
    getopts = sources."getopts-2.2.5" {
      dependencies = [];
    };
    interpret = sources."interpret-2.2.0" {
      dependencies = [];
    };
    is-core-module = sources."is-core-module-2.8.1" {
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
    resolve = sources."resolve-1.22.0" {
      dependencies = [];
    };
    resolve-from = sources."resolve-from-5.0.0" {
      dependencies = [];
    };
    supports-preserve-symlinks-flag = sources."supports-preserve-symlinks-flag-1.0.0" {
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
    pg-pool = sources."pg-pool-3.5.1" {
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
    "@colors/colors" = sources."@colors/colors-1.5.0" {
      dependencies = [];
    };
    "@dabh/diagnostics" = sources."@dabh/diagnostics-2.0.3" {
      dependencies = [];
    };
    async = sources."async-3.2.3" {
      dependencies = [];
    };
    color = sources."color-3.2.1" {
      dependencies = [];
    };
    color-convert = sources."color-convert-1.9.3" {
      dependencies = [];
    };
    color-name = sources."color-name-1.1.3" {
      dependencies = [];
    };
    color-string = sources."color-string-1.9.0" {
      dependencies = [];
    };
    colorspace = sources."colorspace-1.1.4" {
      dependencies = [];
    };
    enabled = sources."enabled-2.0.0" {
      dependencies = [];
    };
    fecha = sources."fecha-4.2.1" {
      dependencies = [];
    };
    "fn.name" = sources."fn.name-1.1.0" {
      dependencies = [];
    };
    is-arrayish = sources."is-arrayish-0.3.2" {
      dependencies = [];
    };
    is-stream = sources."is-stream-2.0.1" {
      dependencies = [];
    };
    kuler = sources."kuler-2.0.0" {
      dependencies = [];
    };
    logform = sources."logform-2.4.0" {
      dependencies = [];
    };
    one-time = sources."one-time-1.0.0" {
      dependencies = [];
    };
    readable-stream = sources."readable-stream-3.6.0" {
      dependencies = [];
    };
    safe-stable-stringify = sources."safe-stable-stringify-2.3.1" {
      dependencies = [];
    };
    simple-swizzle = sources."simple-swizzle-0.2.2" {
      dependencies = [];
    };
    stack-trace = sources."stack-trace-0.0.10" {
      dependencies = [];
    };
    text-hex = sources."text-hex-1.0.0" {
      dependencies = [];
    };
    triple-beam = sources."triple-beam-1.3.0" {
      dependencies = [];
    };
    winston-transport = sources."winston-transport-4.5.0" {
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