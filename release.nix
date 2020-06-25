{ nixopsSrc ? { outPath = ./.; revCount = 0; shortRev = "abcdef"; rev = "HEAD"; }
, officialRelease ? false
, nixpkgs ? <nixpkgs>
}:

let
  pkgs = import nixpkgs { };
  version = "1.7" + (if officialRelease then "" else "pre${toString nixopsSrc.revCount}_${nixopsSrc.shortRev}");

in

rec {

  tarball = pkgs.releaseTools.sourceTarball {
    name = "nixops-tarball";

    src = nixopsSrc;

    inherit version;

    officialRelease = true; # hack

    buildInputs = [ pkgs.git pkgs.libxslt pkgs.docbook5_xsl ];

    postUnpack = ''
      # Clean up when building from a working tree.
      if [ -d $sourceRoot/.git ]; then
        (cd $sourceRoot && (git ls-files -o | xargs -r rm -v))
      fi
    '';

    distPhase =
      ''
        releaseName=nixops-$VERSION
        mkdir ../$releaseName
        cp -prd . ../$releaseName
        rm -rf ../$releaseName/.git
        mkdir $out/tarballs
        tar  cvfj $out/tarballs/$releaseName.tar.bz2 -C .. $releaseName
      '';
  };

  build = pkgs.lib.genAttrs [ "x86_64-linux" "i686-linux" "x86_64-darwin" ] (system:
    with import nixpkgs { inherit system; };

    python2Packages.buildPythonApplication rec {
      name = "nixops-${version}";

      src = "${tarball}/tarballs/*.tar.bz2";

      buildInputs = [ python2Packages.nose python2Packages.coverage ];

      nativeBuildInputs = [ pkgs.mypy ];

      propagatedBuildInputs = with python2Packages;
        [ prettytable
          boto
          boto3
          hetzner
          libcloud
          libvirt
          adal
          # Go back to sqlite once Python 2.7.13 is released
          pysqlite
          datadog
          digital-ocean
          typing
        ] ++
        #FIXME add back once https://github.com/NixOS/nixops/pull/1131
        # is reverted.
        (lib.optional false [
          azure-storage
          azure-mgmt-compute
          azure-mgmt-network
          azure-mgmt-resource
          azure-mgmt-storage
        ]);

      # For "nix-build --run-env".
      shellHook = ''
        export PYTHONPATH=$(pwd):$PYTHONPATH
        export PATH=$(pwd)/scripts:${openssh}/bin:$PATH
      '';

      doCheck = true;

      postCheck = ''
        # We have to unset PYTHONPATH here since it will pick enum34 which collides
        # with python3 own module. This can be removed when nixops is ported to python3.
        PYTHONPATH= mypy --cache-dir=/dev/null nixops

        # smoke test
        HOME=$TMPDIR $out/bin/nixops --version
      '';

      # Needed by libcloud during tests
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

      # Add openssh to nixops' PATH. On some platforms, e.g. CentOS and RHEL
      # the version of openssh is causing errors when have big networks (40+)
      makeWrapperArgs = ["--prefix" "PATH" ":" "${openssh}/bin" "--set" "PYTHONPATH" ":"];

      postInstall =
        ''
          # Backward compatibility symlink.
          ln -s nixops $out/bin/charon

          mkdir -p $out/share/nix/nixops
          cp -av nix/* $out/share/nix/nixops
        '';

      meta.description = "Nix package for ${stdenv.system}";
    });

  # This is included here, so it's easier to fetch by the newly installed
  # Hetzner machine directly instead of waiting for ages if you have a
  # connection with slow upload speed.
  hetznerBootstrap = import ./nix/hetzner-bootstrap.nix;

  tests.none_backend = (import ./tests/none-backend.nix {
    nixops = build.x86_64-linux;
    system = "x86_64-linux";
  }).test;

  tests.hetzner_backend = (import ./tests/hetzner-backend {
    nixops = build.x86_64-linux;
    system = "x86_64-linux";
  }).test;
}
