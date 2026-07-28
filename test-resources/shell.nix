# Network-free fixture: builtins.derivation needs no nixpkgs evaluation.
builtins.derivation {
  name = "eshell-nix-shell-test";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "printf fixture > $out" ];
  ENS_NIX_TEST = "from-local-nix";
  ENS_NIX_MULTILINE = "first\nsecond";
}
