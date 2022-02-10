## osx develop

When building docker image locally on osx (rarely necessary), you'll need a remote nix builder.
Build the docker image from osx with this command

```console
sudo nix -L build .#packages.x86_64-linux.import-bundles -j0
```
