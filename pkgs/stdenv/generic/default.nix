let lib = import ../../../lib; in lib.makeOverridable (

{ system, name ? "stdenv", preHook ? "", initialPath, cc, shell
, allowedRequisites ? null, extraAttrs ? {}, overrides ? (pkgs: {}), config

, # The `fetchurl' to use for downloading curl and its dependencies
  # (see all-packages.nix).
  fetchurlBoot

, setupScript ? ./setup.sh

, extraBuildInputs ? []
}:

let

  allowUnfree = config.allowUnfree or false || builtins.getEnv "NIXPKGS_ALLOW_UNFREE" == "1";

  # Allowed licenses, defaults to no licenses
  whitelistedLicenses = config.whitelistedLicenses or [];

  # Blacklisted licenses, default to no licenses
  blacklistedLicenses = config.blacklistedLicenses or [];

  # Alow granular checks to allow only some unfree packages
  # Example:
  # {pkgs, ...}:
  # {
  #   allowUnfree = false;
  #   allowUnfreePredicate = (x: pkgs.lib.hasPrefix "flashplayer-" x.name);
  # }
  allowUnfreePredicate = config.allowUnfreePredicate or (x: false);

  allowBroken = config.allowBroken or false || builtins.getEnv "NIXPKGS_ALLOW_BROKEN" == "1";

  unsafeGetAttrPos = builtins.unsafeGetAttrPos or (n: as: null);

  isUnfree = licenses: lib.lists.any (l:
    !l.free or true || l == "unfree" || l == "unfree-redistributable") licenses;

  defaultNativeBuildInputs = extraBuildInputs ++
    [ ../../build-support/setup-hooks/move-docs.sh
      ../../build-support/setup-hooks/compress-man-pages.sh
      ../../build-support/setup-hooks/strip.sh
      ../../build-support/setup-hooks/patch-shebangs.sh
      ../../build-support/setup-hooks/move-sbin.sh
      ../../build-support/setup-hooks/move-lib64.sh
      cc
    ];

  # Add a utility function to produce derivations that use this
  # stdenv and its shell.
  mkDerivation = attrs:
    let
      pos =
        if attrs.meta.description or null != null then
          unsafeGetAttrPos "description" attrs.meta
        else
          unsafeGetAttrPos "name" attrs;
      pos' = if pos != null then "‘" + pos.file + ":" + toString pos.line + "’" else "«unknown-file»";

      throwEvalHelp = unfreeOrBroken: whatIsWrong:
        assert (builtins.elem unfreeOrBroken [ "Unfree"
                                               "Broken"
                                               "BlacklistedLicense"
                                             ]);
        throw ''
          Package ‘${attrs.name}’ in ${pos'} ${whatIsWrong}, refusing to evaluate.
          For `nixos-rebuild` you can set
            { nixpkgs.config.allow${unfreeOrBroken} = true; }
          in configuration.nix to override this.
          For `nix-env` you can add
            { allow${unfreeOrBroken} = true; }
          to ~/.nixpkgs/config.nix.
        '';

      # Check whether unfree packages are allowed and if not, whether the
      # package has an unfree license and is not explicitely allowed by the
      # `allowUNfreePredicate` function.
      hasDeniedUnfreeLicense = attrs:
        !allowUnfree &&
        isUnfree (lib.lists.toList attrs.meta.license or []) &&
        !allowUnfreePredicate attrs;

      # Check whether two sets are mutual exclusive
      mutualExclusive = a: b:
        (builtins.length a) == 0 ||
        (!(builtins.elem (builtins.head a) b) &&
         mutualExclusive (builtins.tail a) b);

      # Check whether an package has the license set
      licenseCheckable = attr:
        builtins.hasAttr "meta" attrs && builtins.hasAttr "license" attrs.meta;

      # Check whether the license of the package is whitelisted.
      # If the package has no license, print a warning about this and allow the
      # package (return that it is actually whitelisted)
      hasWhitelistedLicense = attrs:
        if licenseCheckable attrs then
          builtins.elem attrs.meta.license whitelistedLicenses
        else
          #builtins.trace "Has no license: ${attrs.name}, allowing installation"
                         true;

      # Check whether the license of the package is blacklisted.
      # If the package has no license, print a warning about this and allow the
      # package (return that it is actually not blacklisted)
      hasBlacklistedLicense = attrs:
        if licenseCheckable attrs then
          builtins.elem attrs.meta.license blacklistedLicenses
        else
          #builtins.trace "Has no license: ${attrs.name}, allowing installation"
                         false;

    in
    if !(mutualExclusive whitelistedLicenses blacklistedLicenses) then
      throw ''
          Package blacklist (${blacklistedLicenses}) and whitelist
          (${whitelistedLicenses}) are not mutual exclusive.
      ''
    else if hasDeniedUnfreeLicense attrs &&
            !(hasWhitelistedLicense attrs) then
      throwEvalHelp "Unfree" "has an unfree license which is not whitelisted"
    else if hasBlacklistedLicense attrs then
      throwEvalHelp "BlacklistedLicense"
                    "has a license which is blacklisted"
    else if !allowBroken && attrs.meta.broken or false then
      throwEvalHelp "Broken" "is marked as broken"
    else if !allowBroken && attrs.meta.platforms or null != null && !lib.lists.elem result.system attrs.meta.platforms then
      throwEvalHelp "Broken" "is not supported on ‘${result.system}’"
    else
      lib.addPassthru (derivation (
        (removeAttrs attrs ["meta" "passthru" "crossAttrs"])
        // (let
          buildInputs = attrs.buildInputs or [];
          nativeBuildInputs = attrs.nativeBuildInputs or [];
          propagatedBuildInputs = attrs.propagatedBuildInputs or [];
          propagatedNativeBuildInputs = attrs.propagatedNativeBuildInputs or [];
          crossConfig = attrs.crossConfig or null;
        in
        {
          builder = attrs.realBuilder or shell;
          args = attrs.args or ["-e" (attrs.builder or ./default-builder.sh)];
          stdenv = result;
          system = result.system;
          userHook = config.stdenv.userHook or null;
          __ignoreNulls = true;

          # Inputs built by the cross compiler.
          buildInputs = if crossConfig != null then buildInputs else [];
          propagatedBuildInputs = if crossConfig != null then propagatedBuildInputs else [];
          # Inputs built by the usual native compiler.
          nativeBuildInputs = nativeBuildInputs ++ (if crossConfig == null then buildInputs else []);
          propagatedNativeBuildInputs = propagatedNativeBuildInputs ++
            (if crossConfig == null then propagatedBuildInputs else []);
        }))) (
      {
        # The meta attribute is passed in the resulting attribute set,
        # but it's not part of the actual derivation, i.e., it's not
        # passed to the builder and is not a dependency.  But since we
        # include it in the result, it *is* available to nix-env for
        # queries.  We also a meta.position attribute here to
        # identify the source location of the package.
        meta = attrs.meta or {} // (if pos != null then {
          position = pos.file + ":" + (toString pos.line);
        } else {});
        passthru = attrs.passthru or {};
      } //
      # Pass through extra attributes that are not inputs, but
      # should be made available to Nix expressions using the
      # derivation (e.g., in assertions).
      (attrs.passthru or {}));

  # The stdenv that we are producing.
  result =
    derivation (
    (if isNull allowedRequisites then {} else { allowedRequisites = allowedRequisites ++ defaultNativeBuildInputs; }) //
    {
      inherit system name;

      builder = shell;

      args = ["-e" ./builder.sh];

      setup = setupScript;

      inherit preHook initialPath shell defaultNativeBuildInputs;
    })

    // rec {

      meta.description = "The default build environment for Unix packages in Nixpkgs";

      # Utility flags to test the type of platform.
      isDarwin = system == "x86_64-darwin";
      isLinux = system == "i686-linux"
             || system == "x86_64-linux"
             || system == "powerpc-linux"
             || system == "armv5tel-linux"
             || system == "armv6l-linux"
             || system == "armv7l-linux"
             || system == "mips64el-linux";
      isGNU = system == "i686-gnu"; # GNU/Hurd
      isGlibc = isGNU # useful for `stdenvNative'
             || isLinux
             || system == "x86_64-kfreebsd-gnu";
      isSunOS = system == "i686-solaris"
             || system == "x86_64-solaris";
      isCygwin = system == "i686-cygwin"
              || system == "x86_64-cygwin";
      isFreeBSD = system == "i686-freebsd"
              || system == "x86_64-freebsd";
      isOpenBSD = system == "i686-openbsd"
              || system == "x86_64-openbsd";
      isBSD = system == "i686-freebsd"
           || system == "x86_64-freebsd"
           || system == "i686-openbsd"
           || system == "x86_64-openbsd"
           || system == "x86_64-darwin";
      isi686 = system == "i686-linux"
            || system == "i686-gnu"
            || system == "i686-freebsd"
            || system == "i686-openbsd"
            || system == "i386-sunos";
      isx86_64 = system == "x86_64-linux"
              || system == "x86_64-darwin"
              || system == "x86_64-freebsd"
              || system == "x86_64-openbsd"
              || system == "x86_64-solaris";
      is64bit = system == "x86_64-linux"
             || system == "x86_64-darwin"
             || system == "x86_64-freebsd"
             || system == "x86_64-openbsd"
             || system == "x86_64-solaris";
      isMips = system == "mips-linux"
            || system == "mips64el-linux";
      isArm = system == "armv5tel-linux"
           || system == "armv6l-linux"
           || system == "armv7l-linux";
      isBigEndian = system == "powerpc-linux";

      # Whether we should run paxctl to pax-mark binaries.
      needsPax = isLinux;

      inherit mkDerivation;

      # For convenience, bring in the library functions in lib/ so
      # packages don't have to do that themselves.
      inherit lib;

      inherit fetchurlBoot;

      inherit overrides;

      inherit cc;
    }

    # Propagate any extra attributes.  For instance, we use this to
    # "lift" packages like curl from the final stdenv for Linux to
    # all-packages.nix for that platform (meaning that it has a line
    # like curl = if stdenv ? curl then stdenv.curl else ...).
    // extraAttrs;

in result)
