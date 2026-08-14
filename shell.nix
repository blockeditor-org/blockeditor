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

    # wgpu
    libGL
    vulkan-headers
    vulkan-loader
    vulkan-validation-layers
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

    # wgpu
    libGL
    vulkan-headers
    vulkan-loader
    vulkan-validation-layers
  ]);
}

# note that this is not fully working yet: warnings are printed:

# Warning: Path to given binary
#   /nix/store/i0wy4k4zsxx0wk3yyx3xrzyjg4cp81h5-nvidia-x11-580.119.02-6.12.76/lib/libGLX_nvidia.so.580.119.02
# was found to differ from OS loaded path
#   /nix/store/i0wy4k4zsxx0wk3yyx3xrzyjg4cp81h5-nvidia-x11-580.119.02-6.12.76/lib/libGLX_nvidia.so.0

# Warning: terminator_CreateInstance: Received return code -3 from call to vkCreateInstance in ICD
#   /nix/store/xqbqrsnsxskwksghskiapnfnk0gdc2q9-mesa-25.2.6/lib/libvulkan_dzn.so
# Skipping this driver.

# if glfw and dawn are in nix-pkgs, we can probably build using system integration options instead of statically linking glfw
# potentially requiring patching the packages to use b.systemIntegrationOption()
