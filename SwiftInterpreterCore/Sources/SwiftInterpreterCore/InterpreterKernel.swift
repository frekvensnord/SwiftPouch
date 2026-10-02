import Foundation
import ShellKit
import SwiftScriptInterpreter

private struct ActiveBindingScope: Sendable {
    var lowerBound: Int
    var upperBound: Int
    let bindings: [ViewConditionalBinding]
}

private struct ResolvedConditionalSource: Sendable {
    let source: String
    let bindingScopes: [ActiveBindingScope]
}

private struct ScopedExpressionKey: Hashable {
    let expression: String
    let bindings: [ViewConditionalBinding]
}

/// The value and console output produced by one source evaluation.
public struct EvaluationResult: Equatable, Sendable {
    public let value: String
    public let standardOutput: String

    public init(value: String, standardOutput: String) {
        self.value = value
        self.standardOutput = standardOutput
    }
}

/// One freshly loaded app entry and its currently lowered root-view snapshot.
public struct InterpretedAppViewSnapshot: Sendable {
    public let sourceFileName: String
    public let entryPoint: InterpretedAppEntryPoint
    public let rootView: RuntimeViewNode

    let sourceSnapshot: ProjectSourceSnapshot

    init(
        sourceSnapshot: ProjectSourceSnapshot,
        entryPoint: InterpretedAppEntryPoint,
        rootView: RuntimeViewNode
    ) {
        self.sourceFileName = sourceSnapshot.fileName
        self.sourceSnapshot = sourceSnapshot
        self.entryPoint = entryPoint
        self.rootView = rootView
    }
}

/// Owns one interpreter instance for the lifetime of a runtime session.
///
/// One kernel is bound to one project workspace. Each evaluation binds a
/// task-local ShellKit context rooted at that workspace, while declarations
/// from ordinary `evaluate(_:)` calls remain until reset. Source-script reloads
/// and app-view reloads each start a fresh interpreter scope.
public actor InterpreterKernel {
    private let workspace: ProjectWorkspace
    private let sourceAnalyzer: SourceAnalyzer
    private let sourceFileStore: ProjectSourceFileStore
    private let viewExpressionLowerer: SwiftUIViewExpressionLowerer
    private let viewConditionalSourceEditor: ViewConditionalSourceEditor
    private let viewBodySourceEditor: ViewBodySourceEditor
    private let customViewSourceExpander: CustomViewSourceExpander
    private let appEntryPointSourceExtractor: AppEntryPointSourceExtractor
    private var interpreter = Interpreter()
    private var initializedViewStateOwners: [String: String] = [:]
    private var registeredRuntimeActions: [RuntimeActionID: String] = [:]
    private var evaluationInProgress = false
    private var evaluationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(workspace: ProjectWorkspace, sourceAnalyzer: SourceAnalyzer = SourceAnalyzer()) {
        self.workspace = workspace
        self.sourceAnalyzer = sourceAnalyzer
        self.sourceFileStore = ProjectSourceFileStore(workspace: workspace)
        self.viewExpressionLowerer = SwiftUIViewExpressionLowerer()
        self.viewConditionalSourceEditor = ViewConditionalSourceEditor()
        self.viewBodySourceEditor = ViewBodySourceEditor()
        self.customViewSourceExpander = CustomViewSourceExpander()
        self.appEntryPointSourceExtractor = AppEntryPointSourceExtractor()
    }

    /// Reports imports, known runtime requirements, and source diagnostics.
    public func analyze(_ source: String, fileName: String = "<memory>") -> SourceAnalysis {
        sourceAnalyzer.analyze(source, fileName: fileName)
    }

    /// Resolves the interpreted app's @main declaration and WindowGroup root type.
    /// The native host continues to own the app lifecycle and renderer.
    public func resolveAppEntryPoint(in source: String) throws -> InterpretedAppEntryPoint {
        try appEntryPointSourceExtractor.extract(from: source)
    }

    /// Lowers a supported SwiftUI expression using the current interpreter scope.
    ///
    /// Boolean conditions and supported optional bindings choose branches from
    /// the current interpreter scope. Dynamic `Text` arguments and `.disabled`
    /// values in the selected branch are evaluated as snapshots with the
    /// branch's optional bindings in scope. Both branches are structurally
    /// checked before selection.
    public func lowerViewExpression(_ source: String) async throws -> RuntimeViewNode {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        return try await lowerViewExpressionInCurrentScope(source)
    }

    private func lowerViewExpressionInCurrentScope(
        _ source: String,
        stateDeclarations: [ViewStateDeclaration] = [],
        stateTypeName: String? = nil
    ) async throws -> RuntimeViewNode {
        let allTextSites = try viewExpressionLowerer.dynamicStringExpressionSites(in: source)
        let allTextExpressions = Array(Set(allTextSites.map(\.expression))).sorted()
        let dynamicConditions = try viewExpressionLowerer.dynamicBooleanConditions(in: source)
        let dynamicDisabledExpressions = try viewExpressionLowerer.dynamicBooleanModifierArguments(in: source)
        guard !allTextSites.isEmpty
                || !dynamicConditions.isEmpty
                || !dynamicDisabledExpressions.isEmpty else {
            let loweredView = try viewExpressionLowerer.lowerRecordingActions(source)
            if let stateTypeName {
                try await seedViewStateDeclarations(stateDeclarations, typeName: stateTypeName)
            }
            registeredRuntimeActions = loweredView.actions
            return loweredView.node
        }

        let textPlaceholders = Dictionary(uniqueKeysWithValues: allTextExpressions.map { ($0, "") })
        let conditionPlaceholders = Dictionary(uniqueKeysWithValues: dynamicConditions.map { ($0, false) })
        let disabledPlaceholders = Dictionary(uniqueKeysWithValues: dynamicDisabledExpressions.map { ($0, false) })
        _ = try SwiftUIViewExpressionLowerer(
            resolvedDynamicStrings: textPlaceholders,
            resolvedDynamicConditions: conditionPlaceholders,
            resolvedDynamicBooleans: disabledPlaceholders
        ).lower(source)

        if let stateTypeName {
            try await seedViewStateDeclarations(stateDeclarations, typeName: stateTypeName)
        }
        let resolvedConditionals = try await resolveViewConditionalBranches(source)
        let selectedSource = resolvedConditionals.source
        let selectedTextSites = try viewExpressionLowerer.dynamicStringExpressionSites(in: selectedSource)
        let selectedDisabledSites = try viewExpressionLowerer.dynamicBooleanModifierArgumentSites(in: selectedSource)

        let resolvedStringSites: [Int: String]
        if selectedTextSites.isEmpty {
            resolvedStringSites = [:]
        } else {
            resolvedStringSites = try await resolveDynamicTextExpressions(
                selectedTextSites,
                bindingScopes: resolvedConditionals.bindingScopes
            )
        }

        let resolvedDisabledSites: [Int: Bool]
        if selectedDisabledSites.isEmpty {
            resolvedDisabledSites = [:]
        } else {
            resolvedDisabledSites = try await resolveDynamicBooleanModifierArguments(
                selectedDisabledSites,
                bindingScopes: resolvedConditionals.bindingScopes
            )
        }

        let loweredView = try SwiftUIViewExpressionLowerer(
            resolvedDynamicStrings: [:],
            resolvedDynamicBooleans: [:],
            resolvedDynamicStringSites: resolvedStringSites,
            resolvedDynamicBooleanSites: resolvedDisabledSites
        ).lowerRecordingActions(selectedSource)
        registeredRuntimeActions = loweredView.actions
        return loweredView.node
    }

    /// Extracts one named struct's computed body and lowers its view content.
    ///
    /// The extracted expression goes through the same interpreter-backed path
    /// as lowerViewExpression(_:), so it observes the current scope and
    /// optional-binding rules. Simple @State String and Bool initializers are
    /// seeded once into this kernel's interpreter scope and remain mutable
    /// through ordinary evaluate(_:) calls. Simple top-level custom View
    /// structs using synthesized memberwise initializers are expanded
    /// recursively before lowering. Multiple top-level body expressions are
    /// treated as a Group. This does not evaluate the rest of the type.
    public func lowerViewBody(in source: String, typeName: String) async throws -> RuntimeViewNode {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        return try await lowerViewBodyInCurrentScope(in: source, typeName: typeName)
    }

    private func lowerViewBodyInCurrentScope(
        in source: String,
        typeName: String
    ) async throws -> RuntimeViewNode {

        let extractedBody = try viewBodySourceEditor.extract(in: source, typeName: typeName)
        let expandedExpression = try customViewSourceExpander.expand(
            extractedBody.expression,
            from: source,
            rootTypeName: typeName
        )
        return try await lowerViewExpressionInCurrentScope(
            expandedExpression,
            stateDeclarations: extractedBody.stateDeclarations,
            stateTypeName: typeName
        )
    }

    /// Persists a reference to a user-selected `.swift` file for this project.
    public func linkSourceFile(at url: URL) async throws -> ProjectSourceFileReference {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        let store = sourceFileStore
        return try await Task.detached(priority: .userInitiated) {
            try store.link(url)
        }.value
    }

    /// Returns the linked filename and link time without exposing bookmark data.
    public func linkedSourceFile() async throws -> ProjectSourceFileReference? {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        let store = sourceFileStore
        return try await Task.detached(priority: .utility) {
            try store.linkedFile()
        }.value
    }

    /// Removes this project's saved link while leaving the source file untouched.
    public func unlinkSourceFile() async throws {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        let store = sourceFileStore
        try await Task.detached(priority: .utility) {
            try store.unlink()
        }.value
    }

    /// Reads the linked file again and evaluates it in a fresh interpreter scope.
    ///
    /// The file read, preflight, and evaluation are serialized with other kernel
    /// operations so the run always uses one consistent source snapshot.
    public func reloadAndRun() async throws -> EvaluationResult {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        let store = sourceFileStore
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try store.readLinkedSource()
        }.value

        let analysis = sourceAnalyzer.analyze(snapshot.source, fileName: snapshot.fileName)
        guard analysis.isReadyForEvaluation else {
            throw SourcePreflightError(analysis: analysis)
        }

        return try await evaluateLocked(snapshot.source, resetInterpreter: true)
    }

    /// Reloads the linked SwiftUI app and lowers its root view for the host renderer.
    ///
    /// This path deliberately executes only the root view's supported snapshot
    /// expressions. It does not evaluate every top-level app declaration or run
    /// the complete-source module preflight; those integrations are separate
    /// runtime work. Each reload starts from a fresh interpreter scope and
    /// replaces the active button-action table.
    public func reloadAndRunApp() async throws -> InterpretedAppViewSnapshot {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        let store = sourceFileStore
        let sourceSnapshot = try await Task.detached(priority: .userInitiated) {
            try store.readLinkedSource()
        }.value
        let entryPoint = try appEntryPointSourceExtractor.extract(from: sourceSnapshot.source)

        resetInterpreterScope()
        let rootView = try await lowerViewBodyInCurrentScope(
            in: sourceSnapshot.source,
            typeName: entryPoint.rootViewTypeName
        )
        return InterpretedAppViewSnapshot(
            sourceSnapshot: sourceSnapshot,
            entryPoint: entryPoint,
            rootView: rootView
        )
    }

    /// Rebuilds one displayed root view after an interpreted action, keeping its
    /// interpreter scope and the source snapshot from the last Reload & Run.
    public func refreshAppView(_ snapshot: InterpretedAppViewSnapshot) async throws -> InterpretedAppViewSnapshot {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        let rootView = try await lowerViewBodyInCurrentScope(
            in: snapshot.sourceSnapshot.source,
            typeName: snapshot.entryPoint.rootViewTypeName
        )
        return InterpretedAppViewSnapshot(
            sourceSnapshot: snapshot.sourceSnapshot,
            entryPoint: snapshot.entryPoint,
            rootView: rootView
        )
    }

    /// Evaluates source inside this project's sandbox and captures `print` output.
    /// Declarations remain available to later `evaluate(_:)` calls in this session.
    public func evaluate(_ source: String) async throws -> EvaluationResult {
        let analysis = sourceAnalyzer.analyze(source)
        guard analysis.isReadyForEvaluation else {
            throw SourcePreflightError(analysis: analysis)
        }

        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        return try await evaluateLocked(source, resetInterpreter: false)
    }

    /// Runs a button action produced by the most recently lowered view tree.
    /// Action source executes in the existing project interpreter scope.
    public func performAction(_ actionID: RuntimeActionID) async throws -> EvaluationResult {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        guard let actionSource = registeredRuntimeActions[actionID] else {
            throw RuntimeActionError.unknownAction(actionID)
        }
        guard !actionSource.isEmpty else {
            return EvaluationResult(value: "", standardOutput: "")
        }
        return try await evaluateLocked(actionSource, resetInterpreter: false)
    }

    /// Starts a fresh interpreter session and clears its in-memory globals.
    public func reset() async {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }
        resetInterpreterScope()
    }

    private func evaluateLocked(_ source: String, resetInterpreter: Bool) async throws -> EvaluationResult {
        if resetInterpreter {
            resetInterpreterScope()
        }

        let output = OutputSink()
        let projectPath = workspace.rootURL.path
        let shell = Shell(
            stdout: output,
            environment: Environment(variables: [
                "HOME": projectPath,
                "PWD": projectPath
            ]),
            sandbox: Sandbox.rooted(at: workspace.rootURL, allowedHosts: []),
            hostInfo: .synthetic
        )

        do {
            let value = try await shell.withCurrent {
                try await self.evaluateSource(source)
            }
            output.finish()
            return EvaluationResult(value: value, standardOutput: await output.readAllString())
        } catch {
            output.finish()
            _ = await output.readAllString()
            throw error
        }
    }

    private func acquireEvaluationSlot() async {
        guard evaluationInProgress else {
            evaluationInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            evaluationWaiters.append(continuation)
        }
    }

    private func releaseEvaluationSlot() {
        if evaluationWaiters.isEmpty {
            evaluationInProgress = false
        } else {
            evaluationWaiters.removeFirst().resume()
        }
    }

    private func evaluateSource(_ source: String) async throws -> String {
        let value = try await interpreter.eval(source)
        return String(describing: value)
    }

    private func resetInterpreterScope() {
        interpreter = Interpreter()
        initializedViewStateOwners.removeAll()
        registeredRuntimeActions.removeAll()
    }

    private func seedViewStateDeclarations(
        _ declarations: [ViewStateDeclaration],
        typeName: String
    ) async throws {
        for declaration in declarations {
            if let owner = initializedViewStateOwners[declaration.name], owner != typeName {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "State property \(declaration.name) is already initialized for \(owner)"
                )
            }
        }

        let pending = declarations.filter { initializedViewStateOwners[$0.name] == nil }
        guard !pending.isEmpty else {
            return
        }

        let output = OutputSink()
        let projectPath = workspace.rootURL.path
        let shell = Shell(
            stdout: output,
            environment: Environment(variables: [
                "HOME": projectPath,
                "PWD": projectPath
            ]),
            sandbox: Sandbox.rooted(at: workspace.rootURL, allowedHosts: []),
            hostInfo: .synthetic
        )

        do {
            try await shell.withCurrent {
                for declaration in pending {
                    try await self.seedViewStateDeclaration(declaration, typeName: typeName)
                }
            }
            output.finish()
            _ = await output.readAllString()
        } catch {
            output.finish()
            _ = await output.readAllString()
            throw error
        }
    }

    private func seedViewStateDeclaration(
        _ declaration: ViewStateDeclaration,
        typeName: String
    ) async throws {
        _ = try await interpreter.eval(
            "var \(declaration.name) = \(declaration.initializer)"
        )
        initializedViewStateOwners[declaration.name] = typeName
    }

    private func resolveViewConditionalBranches(_ source: String) async throws -> ResolvedConditionalSource {
        let output = OutputSink()
        let projectPath = workspace.rootURL.path
        let shell = Shell(
            stdout: output,
            environment: Environment(variables: [
                "HOME": projectPath,
                "PWD": projectPath
            ]),
            sandbox: Sandbox.rooted(at: workspace.rootURL, allowedHosts: []),
            hostInfo: .synthetic
        )

        do {
            let resolvedSource = try await shell.withCurrent {
                try await self.resolveViewConditionalBranchesInCurrentShell(source)
            }
            output.finish()
            _ = await output.readAllString()
            return resolvedSource
        } catch {
            output.finish()
            _ = await output.readAllString()
            throw error
        }
    }

    private func resolveViewConditionalBranchesInCurrentShell(
        _ source: String
    ) async throws -> ResolvedConditionalSource {
        var selectedSource = source
        var resolvedBranchCount = 0
        var bindingScopes: [ActiveBindingScope] = []

        while let conditional = try viewConditionalSourceEditor.firstConditional(in: selectedSource) {
            guard resolvedBranchCount < 1_024 else {
                throw RuntimeViewLoweringError.unsupportedExpression("too many nested view conditionals")
            }

            let conditionValue: Bool
            if conditional.conditionExpression == "true" {
                conditionValue = true
            } else if conditional.conditionExpression == "false" {
                conditionValue = false
            } else {
                let expression: String
                if let conditionExpression = conditional.conditionExpression {
                    expression = conditionExpression
                } else {
                    expression = "if \(conditional.conditionSource) { true } else { false }"
                }
                let scopedExpression = expressionWithOptionalBindings(
                    expression,
                    fallback: "false",
                    activeBindings: activeBindings(at: conditional.startUTF8Offset, in: bindingScopes)
                )
                let value = try await interpreter.eval(scopedExpression)
                let displayValue = String(describing: value)
                guard displayValue == "true" || displayValue == "false" else {
                    throw RuntimeViewLoweringError.unsupportedExpression(
                        "conditional expression is not Bool: \(conditional.conditionSource)"
                    )
                }
                conditionValue = displayValue == "true"
            }

            let replacement = viewConditionalSourceEditor.replacementText(
                for: conditional,
                selecting: conditionValue
            )
            let replacedRange = conditional.startUTF8Offset..<conditional.endUTF8Offset
            let replacementRange = conditional.startUTF8Offset
                ..<(conditional.startUTF8Offset + replacement.utf8.count)
            bindingScopes = try adjustedBindingScopes(
                bindingScopes,
                replacing: replacedRange,
                replacementLength: replacement.utf8.count
            )
            selectedSource = try viewConditionalSourceEditor.replacing(
                conditional,
                in: selectedSource,
                selecting: conditionValue
            )
            if conditionValue, !conditional.bindings.isEmpty {
                bindingScopes.append(
                    ActiveBindingScope(
                        lowerBound: replacementRange.lowerBound,
                        upperBound: replacementRange.upperBound,
                        bindings: conditional.bindings
                    )
                )
            }
            resolvedBranchCount += 1
        }

        return ResolvedConditionalSource(source: selectedSource, bindingScopes: bindingScopes)
    }

    private func resolveDynamicTextExpressions(
        _ sites: [DynamicViewExpressionSite],
        bindingScopes: [ActiveBindingScope]
    ) async throws -> [Int: String] {
        let output = OutputSink()
        let projectPath = workspace.rootURL.path
        let shell = Shell(
            stdout: output,
            environment: Environment(variables: [
                "HOME": projectPath,
                "PWD": projectPath
            ]),
            sandbox: Sandbox.rooted(at: workspace.rootURL, allowedHosts: []),
            hostInfo: .synthetic
        )

        do {
            let values = try await shell.withCurrent {
                try await self.evaluateDynamicTextExpressions(sites, bindingScopes: bindingScopes)
            }
            output.finish()
            _ = await output.readAllString()
            return values
        } catch {
            output.finish()
            _ = await output.readAllString()
            throw error
        }
    }

    private func resolveDynamicBooleanModifierArguments(
        _ sites: [DynamicViewExpressionSite],
        bindingScopes: [ActiveBindingScope]
    ) async throws -> [Int: Bool] {
        let output = OutputSink()
        let projectPath = workspace.rootURL.path
        let shell = Shell(
            stdout: output,
            environment: Environment(variables: [
                "HOME": projectPath,
                "PWD": projectPath
            ]),
            sandbox: Sandbox.rooted(at: workspace.rootURL, allowedHosts: []),
            hostInfo: .synthetic
        )

        do {
            let values = try await shell.withCurrent {
                try await self.evaluateDynamicBooleanModifierArguments(
                    sites,
                    bindingScopes: bindingScopes
                )
            }
            output.finish()
            _ = await output.readAllString()
            return values
        } catch {
            output.finish()
            _ = await output.readAllString()
            throw error
        }
    }

    private func evaluateDynamicBooleanModifierArguments(
        _ sites: [DynamicViewExpressionSite],
        bindingScopes: [ActiveBindingScope]
    ) async throws -> [Int: Bool] {
        var values: [Int: Bool] = [:]
        var cache: [ScopedExpressionKey: Bool] = [:]
        for site in sites {
            let activeBindings = activeBindings(at: site.utf8Offset, in: bindingScopes)
            let key = ScopedExpressionKey(expression: site.expression, bindings: activeBindings)
            if let cachedValue = cache[key] {
                values[site.utf8Offset] = cachedValue
                continue
            }
            let scopedExpression = expressionWithOptionalBindings(
                site.expression,
                fallback: "false",
                activeBindings: activeBindings
            )
            let value = try await interpreter.eval(scopedExpression)
            let displayValue = String(describing: value)
            guard displayValue == "true" || displayValue == "false" else {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "disabled argument is not Bool: \(site.expression)"
                )
            }
            let resolvedValue = displayValue == "true"
            cache[key] = resolvedValue
            values[site.utf8Offset] = resolvedValue
        }
        return values
    }

    private func evaluateDynamicTextExpressions(
        _ sites: [DynamicViewExpressionSite],
        bindingScopes: [ActiveBindingScope]
    ) async throws -> [Int: String] {
        var values: [Int: String] = [:]
        var cache: [ScopedExpressionKey: String] = [:]
        for site in sites {
            let activeBindings = activeBindings(at: site.utf8Offset, in: bindingScopes)
            let key = ScopedExpressionKey(expression: site.expression, bindings: activeBindings)
            if let cachedValue = cache[key] {
                values[site.utf8Offset] = cachedValue
                continue
            }
            let scopedExpression = expressionWithOptionalBindings(
                site.expression,
                fallback: "\"\"",
                activeBindings: activeBindings
            )
            let value = try await interpreter.eval(scopedExpression)
            let resolvedValue = String(describing: value)
            cache[key] = resolvedValue
            values[site.utf8Offset] = resolvedValue
        }
        return values
    }

    private func activeBindings(at offset: Int, in scopes: [ActiveBindingScope]) -> [ViewConditionalBinding] {
        scopes
            .filter { offset >= $0.lowerBound && offset < $0.upperBound }
            .sorted { $0.lowerBound < $1.lowerBound }
            .flatMap(\.bindings)
    }

    private func adjustedBindingScopes(
        _ scopes: [ActiveBindingScope],
        replacing range: Range<Int>,
        replacementLength: Int
    ) throws -> [ActiveBindingScope] {
        let offsetDelta = replacementLength - range.count
        return try scopes.map { scope in
            if scope.upperBound <= range.lowerBound {
                return scope
            }
            if scope.lowerBound >= range.upperBound {
                return ActiveBindingScope(
                    lowerBound: scope.lowerBound + offsetDelta,
                    upperBound: scope.upperBound + offsetDelta,
                    bindings: scope.bindings
                )
            }
            if scope.lowerBound <= range.lowerBound && scope.upperBound >= range.upperBound {
                return ActiveBindingScope(
                    lowerBound: scope.lowerBound,
                    upperBound: scope.upperBound + offsetDelta,
                    bindings: scope.bindings
                )
            }
            throw RuntimeViewLoweringError.malformedSyntax
        }
    }

    private func expressionWithOptionalBindings(
        _ expression: String,
        fallback: String,
        activeBindings: [ViewConditionalBinding]
    ) -> String {
        activeBindings.reversed().reduce(expression) { nestedExpression, binding in
            "if \(binding.clause) { \(nestedExpression) } else { \(fallback) }"
        }
    }
}
