# Agent Guidelines

These load in order from least to most specific, so later files take priority. If your
tool doesn't expand `@` includes automatically, read and follow each of these files in
that order before starting any work.

@Submodules/agents-md-core/AGENTS.md
@Submodules/agents-md-shared/AGENTS.md
@Submodules/agents-md-luau/AGENTS.md

## Plugin Development

- Build and install the plugin with `lune run ./Scripts/BuildPlugin.luau --install`
- This copies the built `.rbxm` to the Studio plugins folder
- Studio automatically reloads the plugin when the file changes, no need to reopen Studio
- Republish plugin icon assets with `assetfile sync` (uploads images from `Assets/` to Roblox and updates `Source/Plugin/Assets.luau`)
