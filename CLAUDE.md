# Claude Code Guidelines

Make sure to load all relevant `CLAUDE.md` files across the repository, including those in submodules.

## Plugin Development

- Build and install the plugin with `lune run ./Scripts/BuildPlugin.luau --install`
- This copies the built `.rbxm` to the Studio plugins folder
- Studio automatically reloads the plugin when the file changes, no need to reopen Studio
- Republish plugin icon assets with `assetfile sync` (uploads images from `Assets/` to Roblox and updates `Source/Plugin/Assets.luau`)
