#!/bin/zsh

# install dependencies
nix flake lock
# if experimental-features is not enabled, this will fail
# nix --extra-experimental-features 'nix-command flakes' flake lock

# run
# well, this didn't work:
#  aborted: nixos-facter is not available in booted installer, use nixos-generate-config. For nixos-facter, you may want to boot an installer image from here instead: https://github.com/nix-community/nixos-images
# so, instead ssh to the machine and:
#  sudo nix run --option experimental-features "nix-command flakes" nixpkgs#nixos-facter -- -o facter.json
# and scp the generated facter.json
#  scp root@netcup-vps:/home/nixos/facter.json .
# nix run github:nix-community/nixos-anywhere -- --generate-hardware-config nixos-facter ./facter.json --flake ./configuration.nix#netcup --target-host root@netcup-vps -i ~/.ssh/netcup_vps_nixos

# disko mode disko should be default, but something broke it just now: https://github.com/nix-community/nixos-anywhere/issues/508
# nix run github:nix-community/nixos-anywhere -- --flake .#netcup --target-host root@netcup-vps -i ~/.ssh/netcup_vps_nixos --disko-mode disko
nix --extra-experimental-features 'nix-command flakes' run github:nix-community/nixos-anywhere -- --flake .#netcup --target-host root@v2202505270128345138.powersrv.de --phases kexec,disko,install,reboot --disko-mode disko
# nix --extra-experimental-features 'nix-command flakes' run github:nix-community/nixos-anywhere -- --flake .#netcup --target-host root@v2202504270128336125.luckysrv.de --phases kexec,install,reboot --disko-mode disko
# Server-Passwörter: Apple Passwords (Repo ist public, hier steht nichts).
