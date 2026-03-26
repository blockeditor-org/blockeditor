let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-25.11";
  pkgs = import nixpkgs { config = {}; overlays = []; };
in

pkgs.mkShellNoCC {
  packages = with pkgs; [
    # include vscode here?

    git
    zig
    rr
    bun

    # linkSystemLibrary
    pkg-config

    # glfw
    wayland
    wayland-protocols
    libxkbcommon
    libx11
    libxrandr
    libxinerama
    libxcursor
    libxi
    libxext
    libxxf86vm
  ];
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
    # glfw
    wayland
    wayland-protocols
    libxkbcommon
    libx11
    libxrandr
    libxinerama
    libxcursor
    libxi
    libxext
    libxxf86vm

    # nix does this using NIX_CFLAGS_COMPILE, maybe we could do that instead?
    # https://github.com/NixOS/nixpkgs/blob/ed142ab1b3a092c4d149245d0c4126a5d7ea00b0/pkgs/by-name/gl/glfw3/package.nix#L102
  ]);
}

# note that this is not fully working yet. `zig build run` spawns an empty window.