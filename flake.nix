{
  description = "Nix shell activation for Emacs Eshell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      emacsFor = pkgs:
        (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages
          (epkgs: [ epkgs.flycheck epkgs.flycheck-package epkgs.package-lint ]);
    in {
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; emacs = emacsFor pkgs; in {
          default = pkgs.mkShell {
            packages = [ emacs pkgs.bashInteractive pkgs.nix pkgs.gnumake ];
          };
        });

      checks = forAllSystems (system:
        let pkgs = pkgsFor system; emacs = emacsFor pkgs; in {
          test = pkgs.stdenvNoCC.mkDerivation {
            name = "eshell-nix-shell-test";
            src = self;
            nativeBuildInputs = [ emacs pkgs.bashInteractive pkgs.gnumake ];
            buildPhase = "make all";
            installPhase = "touch $out";
          };
        });

      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          emacs = emacsFor pkgs;
          test = pkgs.writeShellApplication {
            name = "eshell-nix-shell-test";
            runtimeInputs =
              [ emacs pkgs.bashInteractive pkgs.gnumake pkgs.nix ];
            text = ''
              work=$(mktemp -d)
              trap 'rm -rf "$work"' EXIT
              cp -R ${self}/. "$work"
              chmod -R u+w "$work"
              make -C "$work" all
            '';
          };
        in { default = { type = "app"; program = "${test}/bin/eshell-nix-shell-test"; }; });
    };
}
