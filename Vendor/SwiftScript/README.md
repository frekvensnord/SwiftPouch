# Embedded SwiftScript

This package contains the `SwiftScriptAST` and `SwiftScriptInterpreter` source
targets from Cocoanetics/SwiftScript commit
`d298d01dc1aa34d68700f7d0e37ad26b52b36dfc` under the upstream MIT
license in `LICENSE`. The unused executable, generator, examples, and upstream
tests are omitted. The manifest fixes ShellKit and swift-syntax revisions.

Local interpreter changes are limited to:

- `API/Scope.swift` and `Execution/Interpreter+Closures.swift`: weak class
  capture storage and detachment from the method scope that held `self`.
- `Execution/Interpreter+Structs.swift`: default arguments in custom struct
  initializers.
- `Execution/Interpreter+Calls.swift`: mutating `String.append`.
- `Execution/Interpreter+Members.swift`: `LocalizedError.errorDescription`
  backing for enum `localizedDescription`.

The host's source adapter handles the other target-specific syntax gaps.
