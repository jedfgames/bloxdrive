# Changelog

## 0.0.2
- Replaced GitHub branch-based registry with Cloudflare Worker backed by D1 (SQLite at the edge)
- Added Cloudflare Worker API with atomic transactions for publishing package versions
- Added RbxPackageLoader.configure() for setting registry auth tokens
- Changed load() to return (Instance?, LoadResult) with optional Parent parameter
- Added comprehensive test suite with E2E, Registry, RegistryLifecycle, Serializer, Deserializer, and TreeUtils tests
- Added E2E tests running inside a real Roblox place via Open Cloud Luau Execution API
- Fixed AutoSync pcall capturing boolean instead of marker path
- Fixed PackagePuller reference to non-exported _decodeValue
- Fixed PromptInput header comment to match actual props

## 0.0.1
- Added core RbxPackageLoader library with instance serialization, deserialization, three-way merging, and tree diffing
- Added Registry client for fetching packages from GitHub-based package registry
- Added Studio plugin with publish, pull, and token management toolbar buttons
- Added AutoSync system with AutoPull polling and AutoPush debounced change detection
- Added build scripts and CD pipeline for building and releasing the plugin .rbxm
- Added TreeDiff and Merger test suites
