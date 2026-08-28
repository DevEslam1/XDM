# Contributing to DMX (XDM)

Thank you for contributing to DMX! To maintain our 10/10 quality bar, all submissions must pass our automated quality gates.

## Pull Request Quality Gates

Before submitting a PR, ensure all 4 local gates succeed:

```bash
# 1. Static Analysis (Zero warnings/infos allowed)
flutter analyze

# 2. Code Formatting (Zero unformatted files)
dart format --output=none --set-exit-if-changed lib test

# 3. Unit & Regression Tests (Zero failures allowed)
flutter test --coverage

# 4. Android Build Gate (Kotlin & Layout XML compilation)
cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest
```

## Ground Rules
1. Every bug fix must include a regression test under `test/unit/services/` or `test/features/`.
2. Do not modify or relax existing tests to make new code pass.
3. Keep the presentation, domain, and data layers decoupled according to `ARCHITECTURE.md`.
