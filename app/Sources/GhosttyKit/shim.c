// Intentionally empty: this target exists only to vend the GhosttyKit Clang module
// (ghostty.h) for `import GhosttyKit`. The libghostty static archive itself is linked
// via an explicit -Xlinker flag in Package.swift (swift build can't link a static
// xcframework directly).
