{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShell {
  packages = with pkgs; [
    nushell
    nufmt
    prek
    pgformatter
    shfmt
    mdformat
    yamlfmt
    taplo
    nixfmt
  ];
  shellHook = ''
    prek install
  '';
}
