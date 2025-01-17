{ bash
, brotli
, buildGoModule
, forgejo
, git
, gzip
, lib
, makeWrapper
, nixosTests
, openssh
, pam
, pamSupport ? true
, sqliteSupport ? true
, xorg
, runCommand
, stdenv
, fetchFromGitea
, buildNpmPackage
}:

let
  frontend = buildNpmPackage {
    pname = "forgejo-frontend";
    inherit (forgejo) src version;

    npmDepsHash = "sha256-dB/uBuS0kgaTwsPYnqklT450ejLHcPAqBdDs3JT8Uxg=";

    patches = [
      ./package-json-npm-build-frontend.patch
    ];

    # override npmInstallHook
    installPhase = ''
      mkdir $out
      cp -R ./public $out/
    '';
  };
in
buildGoModule rec {
  pname = "forgejo";
  version = "1.19.4-0";

  src = fetchFromGitea {
    domain = "codeberg.org";
    owner = "forgejo";
    repo = "forgejo";
    rev = "v${version}";
    hash = "sha256-pTcnST8A4gADPBkNago9uwRFEmTx8vNONL/Emer4xLI=";
  };

  vendorHash = "sha256-LKxhNbSIRaP4EGWX6mE26G9CWfoFTrPRjrL4ShpRHWo=";

  subPackages = [ "." ];

  outputs = [ "out" "data" ];

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = lib.optional pamSupport pam;

  patches = [
    ./../gitea/static-root-path.patch
  ];

  postPatch = ''
    substituteInPlace modules/setting/setting.go --subst-var data
  '';

  tags = lib.optional pamSupport "pam"
    ++ lib.optionals sqliteSupport [ "sqlite" "sqlite_unlock_notify" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${version}"
    "-X 'main.Tags=${lib.concatStringsSep " " tags}'"
  ];

  preBuild = ''
    go run build/merge-forgejo-locales.go
  '';

  postInstall = ''
    mkdir $data
    cp -R ./{templates,options} ${frontend}/public $data
    mkdir -p $out
    cp -R ./options/locale $out/locale
    wrapProgram $out/bin/gitea \
      --prefix PATH : ${lib.makeBinPath [ bash git gzip openssh ]}
  '';

  # $data is not available in go-modules.drv and preBuild isn't needed
  overrideModAttrs = (_: {
    postPatch = null;
    preBuild = null;
  });

  passthru = {
    data-compressed = runCommand "forgejo-data-compressed" {
      nativeBuildInputs = [ brotli xorg.lndir ];
    } ''
      mkdir $out
      lndir ${forgejo.data}/ $out/

      # Create static gzip and brotli files
      find -L $out -type f -regextype posix-extended -iregex '.*\.(css|html|js|svg|ttf|txt)' \
        -exec gzip --best --keep --force {} ';' \
        -exec brotli --best --keep --no-copy-stat {} ';'
    '';

    tests = nixosTests.forgejo;
  };

  meta = {
    description = "A self-hosted lightweight software forge";
    homepage = "https://forgejo.org";
    changelog = "https://codeberg.org/forgejo/forgejo/releases/tag/${src.rev}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ emilylange urandom bendlas ];
    broken = stdenv.isDarwin;
    mainProgram = "gitea";
    knownVulnerabilities = [
      ''
        Forgejo's API and web endpoints before version 1.20.5-1 are affected by multiple
        critical security vulnerabilities.

        Non-exhaustive list:
         - reveal comments from issues and pull-requests from private repositories
         - delete comments from issues and pull-requests
         - get private release attachments
         - delete releases and tags
         - get ssh deployment keys (public key)
         - get OAuth2 applications (except for the secret)
         - 2FA not being enforced for the container registry login (docker login)

        There isn't a clear way how to backport and validate all those fixes to the now EOL
        forgejo 1.19.x and we, the forgejo nixpkgs maintainers, decided against bumping the
        release from 1.19.x to 1.20.x due to its breaking nature.
        Given nixpkgs 23.11 has been released by now and nixpkgs 23.05 will reach EOL very
        soon (2023-12-31), please update to nixpkgs 23.11 instead.

        Upstream: https://forgejo.org/2023-11-release-v1-20-5-1/
      ''
    ];
  };
}
