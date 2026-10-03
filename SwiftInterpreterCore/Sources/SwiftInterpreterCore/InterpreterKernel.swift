import Foundation
import ShellKit
import SwiftScriptInterpreter

private struct ActiveBindingScope: Sendable {
    var lowerBound: Int
    var upperBound: Int
    let bindings: [ViewConditionalBinding]
    let forEachBindings: [RuntimeForEachItemBinding]
    let capturedActionBindings: [RuntimeForEachItemBinding]
}

private struct ResolvedConditionalSource: Sendable {
    let source: String
    let bindingScopes: [ActiveBindingScope]
}

private struct ScopedExpressionKey: Hashable {
    let expression: String
    let bindings: [ViewConditionalBinding]
    let forEachBindings: [RuntimeForEachItemBinding]
}

/// The value and console output produced by one source evaluation.
public struct EvaluationResult: Equatable, Sendable {
    public let value: String
    public let standardOutput: String
    public let requestsHostDismissal: Bool

    public init(
        value: String,
        standardOutput: String,
        requestsHostDismissal: Bool = false
    ) {
        self.value = value
        self.standardOutput = standardOutput
        self.requestsHostDismissal = requestsHostDismissal
    }
}

/// One freshly loaded app entry and its currently lowered root-view snapshot.
public struct InterpretedAppViewSnapshot: Sendable {
    public let sourceFileName: String
    public let entryPoint: InterpretedAppEntryPoint
    public let rootView: RuntimeViewNode
    public let scenePhase: RuntimeScenePhase

    let sourceSnapshot: ProjectSourceSnapshot

    init(
        sourceSnapshot: ProjectSourceSnapshot,
        entryPoint: InterpretedAppEntryPoint,
        rootView: RuntimeViewNode,
        scenePhase: RuntimeScenePhase
    ) {
        self.sourceFileName = sourceSnapshot.fileName
        self.sourceSnapshot = sourceSnapshot
        self.entryPoint = entryPoint
        self.rootView = rootView
        self.scenePhase = scenePhase
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
    private let viewForEachSourceEditor: ViewForEachSourceEditor
    private let viewBodySourceEditor: ViewBodySourceEditor
    private let customViewSourceExpander: CustomViewSourceExpander
    private let appEntryPointSourceExtractor: AppEntryPointSourceExtractor
    private let scriptSourceAdapter: SwiftScriptSourceAdapter
    private var interpreter = Interpreter()
    private var optionalVariableTypes: [String: String] = [:]
    private var initializedViewStateOwners: [String: String] = [:]
    private var registeredRuntimeActions: [RuntimeActionID: RuntimeActionRegistration] = [:]
    private let forEachTemporaryPrefix = "__swiftpouch_runtime_foreach_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    private var currentScenePhase: RuntimeScenePhase = .active
    private var interpreterScenePhase: RuntimeScenePhase?
    private var interpreterDismissBridgeInstalled = false
    private var evaluationInProgress = false
    private var evaluationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(workspace: ProjectWorkspace, sourceAnalyzer: SourceAnalyzer = SourceAnalyzer()) {
        self.workspace = workspace
        self.sourceAnalyzer = sourceAnalyzer
        self.sourceFileStore = ProjectSourceFileStore(workspace: workspace)
        self.viewExpressionLowerer = SwiftUIViewExpressionLowerer()
        self.viewConditionalSourceEditor = ViewConditionalSourceEditor()
        self.viewForEachSourceEditor = ViewForEachSourceEditor()
        self.viewBodySourceEditor = ViewBodySourceEditor()
        self.customViewSourceExpander = CustomViewSourceExpander()
        self.appEntryPointSourceExtractor = AppEntryPointSourceExtractor()
        self.scriptSourceAdapter = SwiftScriptSourceAdapter()
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
        let containsForEach = try viewForEachSourceEditor.firstForEach(in: source) != nil
        let allTextSites = try viewExpressionLowerer.dynamicStringExpressionSites(in: source)
        let allTextExpressions = Array(Set(allTextSites.map(\.expression))).sorted()
        let dynamicConditions = try viewExpressionLowerer.dynamicBooleanConditions(in: source)
        let dynamicDisabledExpressions = try viewExpressionLowerer.dynamicBooleanModifierArguments(in: source)
        guard !allTextSites.isEmpty
                || !dynamicConditions.isEmpty
                || !dynamicDisabledExpressions.isEmpty
                || containsForEach else {
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
        let validationSource = containsForEach
            ? try viewForEachSourceEditor.replacingForEachWithBodies(in: source)
            : source
        _ = try SwiftUIViewExpressionLowerer(
            resolvedDynamicStrings: textPlaceholders,
            resolvedDynamicConditions: conditionPlaceholders,
            resolvedDynamicBooleans: disabledPlaceholders
        ).lower(validationSource)

        if let stateTypeName {
            try await seedViewStateDeclarations(stateDeclarations, typeName: stateTypeName)
        }

        var selectedSource = source
        var bindingScopes: [ActiveBindingScope] = []
        var expansionCount = 0
        while true {
            let resolvedConditionals = try await resolveViewConditionalBranches(
                selectedSource,
                bindingScopes: bindingScopes
            )
            selectedSource = resolvedConditionals.source
            bindingScopes = resolvedConditionals.bindingScopes

            guard let site = try viewForEachSourceEditor.firstForEach(in: selectedSource) else {
                break
            }
            guard expansionCount < 1_024 else {
                throw RuntimeViewLoweringError.unsupportedForEach(
                    "too many nested or sibling collection expressions"
                )
            }

            let replacement = try await expandForEach(
                site,
                in: selectedSource,
                bindingScopes: bindingScopes
            )
            let replacedRange = site.startUTF8Offset..<site.endUTF8Offset
            let replacementLength = replacement.source.utf8.count
                - (selectedSource.utf8.count - replacedRange.count)
            bindingScopes = try adjustedBindingScopes(
                bindingScopes,
                replacing: replacedRange,
                replacementLength: replacementLength
            )
            bindingScopes.append(contentsOf: replacement.bindingScopes.map { scope in
                ActiveBindingScope(
                    lowerBound: scope.lowerBound,
                    upperBound: scope.upperBound,
                    bindings: [],
                    forEachBindings: [scope.binding],
                    capturedActionBindings: []
                )
            })
            selectedSource = replacement.source
            expansionCount += 1
        }

        let selectedTextSites = try viewExpressionLowerer.dynamicStringExpressionSites(in: selectedSource)
        let selectedDisabledSites = try viewExpressionLowerer.dynamicBooleanModifierArgumentSites(in: selectedSource)

        let resolvedStringSites: [Int: String]
        if selectedTextSites.isEmpty {
            resolvedStringSites = [:]
        } else {
            resolvedStringSites = try await resolveDynamicTextExpressions(
                selectedTextSites,
                bindingScopes: bindingScopes
            )
        }

        let resolvedDisabledSites: [Int: Bool]
        if selectedDisabledSites.isEmpty {
            resolvedDisabledSites = [:]
        } else {
            resolvedDisabledSites = try await resolveDynamicBooleanModifierArguments(
                selectedDisabledSites,
                bindingScopes: bindingScopes
            )
        }

        let actionBindings = try actionForEachBindings(
            in: selectedSource,
            bindingScopes: bindingScopes
        )

        let loweredView = try SwiftUIViewExpressionLowerer(
            resolvedDynamicStrings: [:],
            resolvedDynamicBooleans: [:],
            resolvedDynamicStringSites: resolvedStringSites,
            resolvedDynamicBooleanSites: resolvedDisabledSites,
            forEachBindingsByActionOffset: actionBindings
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
    public func lowerViewBody(
        in source: String,
        typeName: String,
        scenePhase: RuntimeScenePhase = .active
    ) async throws -> RuntimeViewNode {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        currentScenePhase = scenePhase
        return try await lowerViewBodyInCurrentScope(in: source, typeName: typeName)
    }

    private func lowerViewBodyInCurrentScope(
        in source: String,
        typeName: String
    ) async throws -> RuntimeViewNode {
        try await updateInterpreterScenePhase(currentScenePhase)
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
    public func reloadAndRunApp(
        scenePhase: RuntimeScenePhase = .active
    ) async throws -> InterpretedAppViewSnapshot {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        let store = sourceFileStore
        let sourceSnapshot = try await Task.detached(priority: .userInitiated) {
            try store.readLinkedSource()
        }.value
        let entryPoint = try appEntryPointSourceExtractor.extract(from: sourceSnapshot.source)

        let previousInterpreter = interpreter
        let previousOptionalVariableTypes = optionalVariableTypes
        let previousStateOwners = initializedViewStateOwners
        let previousActions = registeredRuntimeActions
        let previousScenePhase = currentScenePhase
        let previousInterpreterScenePhase = interpreterScenePhase
        let previousDismissBridgeInstalled = interpreterDismissBridgeInstalled
        resetInterpreterScope()
        currentScenePhase = scenePhase
        let rootView: RuntimeViewNode
        do {
            rootView = try await lowerViewBodyInCurrentScope(
                in: sourceSnapshot.source,
                typeName: entryPoint.rootViewTypeName
            )
        } catch {
            interpreter = previousInterpreter
            optionalVariableTypes = previousOptionalVariableTypes
            initializedViewStateOwners = previousStateOwners
            registeredRuntimeActions = previousActions
            currentScenePhase = previousScenePhase
            interpreterScenePhase = previousInterpreterScenePhase
            interpreterDismissBridgeInstalled = previousDismissBridgeInstalled
            throw error
        }
        return InterpretedAppViewSnapshot(
            sourceSnapshot: sourceSnapshot,
            entryPoint: entryPoint,
            rootView: rootView,
            scenePhase: scenePhase
        )
    }

    /// Rebuilds one displayed root view after an interpreted action, keeping its
    /// interpreter scope and the source snapshot from the last Reload & Run.
    public func refreshAppView(
        _ snapshot: InterpretedAppViewSnapshot,
        scenePhase: RuntimeScenePhase? = nil
    ) async throws -> InterpretedAppViewSnapshot {
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }

        let scenePhase = scenePhase ?? snapshot.scenePhase
        currentScenePhase = scenePhase
        let rootView = try await lowerViewBodyInCurrentScope(
            in: snapshot.sourceSnapshot.source,
            typeName: snapshot.entryPoint.rootViewTypeName
        )
        return InterpretedAppViewSnapshot(
            sourceSnapshot: snapshot.sourceSnapshot,
            entryPoint: snapshot.entryPoint,
            rootView: rootView,
            scenePhase: scenePhase
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

        guard let action = registeredRuntimeActions[actionID] else {
            throw RuntimeActionError.unknownAction(actionID)
        }
        guard !action.source.isEmpty else {
            return EvaluationResult(value: "", standardOutput: "")
        }
        // A prior action can fail after requesting dismissal. Clear that request
        // before executing the next action so an unrelated tap cannot consume it.
        if interpreterDismissBridgeInstalled {
            _ = try await evaluateLocked(
                "__swiftpouch_host_dismiss_requested = false",
                resetInterpreter: false
            )
        }
        let result = try await evaluateAction(action)
        let requestsHostDismissal = try await consumeHostDismissalRequest()
        return EvaluationResult(
            value: result.value,
            standardOutput: result.standardOutput,
            requestsHostDismissal: requestsHostDismissal
        )
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
            let value = try await shell.withCurrent { @Sendable in
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
        let prepared = scriptSourceAdapter.prepare(source, optionalVariableTypes: optionalVariableTypes)
        let value = try await interpreter.eval(prepared.source)
        optionalVariableTypes = prepared.optionalVariableTypes
        return String(describing: value)
    }

    private func resetInterpreterScope() {
        interpreter = Interpreter()
        optionalVariableTypes.removeAll()
        initializedViewStateOwners.removeAll()
        registeredRuntimeActions.removeAll()
        interpreterScenePhase = nil
        interpreterDismissBridgeInstalled = false
    }

    private func updateInterpreterScenePhase(_ scenePhase: RuntimeScenePhase) async throws {
        guard interpreterScenePhase != scenePhase else { return }

        let source: String
        if interpreterScenePhase == nil {
            source = """
            enum __SwiftPouchScenePhase {
                case active
                case inactive
                case background
            }
            var __swiftpouch_environment_scenePhase: __SwiftPouchScenePhase = __SwiftPouchScenePhase.\(scenePhase.rawValue)
            var __swiftpouch_host_dismiss_requested = false
            func __swiftpouch_environment_dismiss() {
                __swiftpouch_host_dismiss_requested = true
            }
            """
        } else {
            source = "__swiftpouch_environment_scenePhase = __SwiftPouchScenePhase.\(scenePhase.rawValue)"
        }

        _ = try await evaluateLocked(source, resetInterpreter: false)
        interpreterScenePhase = scenePhase
        interpreterDismissBridgeInstalled = true
    }

    private func consumeHostDismissalRequest() async throws -> Bool {
        guard interpreterDismissBridgeInstalled else { return false }

        let result = try await evaluateLocked(
            "__swiftpouch_host_dismiss_requested",
            resetInterpreter: false
        )
        guard result.value == "true" else { return false }

        _ = try await evaluateLocked(
            "__swiftpouch_host_dismiss_requested = false",
            resetInterpreter: false
        )
        return true
    }

    private func seedViewStateDeclarations(
        _ declarations: [ViewStateDeclaration],
        typeName: String
    ) async throws {
        for declaration in declarations {
            if let owner = initializedViewStateOwners[declaration.storageName], owner != typeName {
                throw RuntimeViewLoweringError.unsupportedExpression(
                    "State property \(declaration.name) is already initialized for \(owner)"
                )
            }
        }

        let pending = declarations.filter { initializedViewStateOwners[$0.storageName] == nil }
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
            try await shell.withCurrent { @Sendable in
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
            "var \(declaration.storageName) = \(declaration.initializer)"
        )
        initializedViewStateOwners[declaration.storageName] = typeName
    }

    private func resolveViewConditionalBranches(
        _ source: String,
        bindingScopes: [ActiveBindingScope]
    ) async throws -> ResolvedConditionalSource {
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
            let resolvedSource = try await shell.withCurrent { @Sendable in
                try await self.resolveViewConditionalBranchesInCurrentShell(
                    source,
                    bindingScopes: bindingScopes
                )
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
        _ source: String,
        bindingScopes initialBindingScopes: [ActiveBindingScope]
    ) async throws -> ResolvedConditionalSource {
        var selectedSource = source
        var resolvedBranchCount = 0
        var bindingScopes = initialBindingScopes

        while let conditional = try viewConditionalSourceEditor.firstConditional(in: selectedSource) {
            guard resolvedBranchCount < 1_024 else {
                throw RuntimeViewLoweringError.unsupportedExpression("too many nested view conditionals")
            }

            let conditionValue = try await evaluateConditional(
                conditional,
                activeBindings: activeBindings(
                    at: conditional.startUTF8Offset,
                    in: bindingScopes
                ),
                forEachBindings: activeForEachBindings(
                    at: conditional.startUTF8Offset,
                    in: bindingScopes
                )
            )

            let replacement = viewConditionalSourceEditor.replacementText(
                for: conditional,
                selecting: conditionValue
            )
            let replacedRange = conditional.startUTF8Offset..<conditional.endUTF8Offset
            let replacementRange = conditional.startUTF8Offset..<(conditional.startUTF8Offset + replacement.utf8.count)
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
                let outerBindings = activeBindings(
                    at: conditional.startUTF8Offset,
                    in: bindingScopes
                )
                let rowBindings = activeForEachBindings(
                    at: conditional.startUTF8Offset,
                    in: bindingScopes
                )
                var captures: [RuntimeForEachItemBinding] = []
                for binding in conditional.bindings {
                    captures.append(RuntimeForEachItemBinding(
                        name: binding.name,
                        value: try await evaluateViewExpression(
                            binding.name,
                            fallback: "nil",
                            activeBindings: outerBindings + conditional.bindings,
                            forEachBindings: rowBindings
                        )
                    ))
                }
                bindingScopes.append(
                    ActiveBindingScope(
                        lowerBound: replacementRange.lowerBound,
                        upperBound: replacementRange.upperBound,
                        bindings: conditional.bindings,
                        forEachBindings: [],
                        capturedActionBindings: captures
                    )
                )
            }
            resolvedBranchCount += 1
        }

        return ResolvedConditionalSource(source: selectedSource, bindingScopes: bindingScopes)
    }

    private func expandForEach(
        _ site: ViewForEachSite,
        in source: String,
        bindingScopes: [ActiveBindingScope]
    ) async throws -> ViewForEachSourceReplacement {
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
            let replacement = try await shell.withCurrent { @Sendable in
                try await self.expandForEachInCurrentShell(
                    site,
                    in: source,
                    bindingScopes: bindingScopes
                )
            }
            output.finish()
            _ = await output.readAllString()
            return replacement
        } catch {
            output.finish()
            _ = await output.readAllString()
            throw error
        }
    }

    private func expandForEachInCurrentShell(
        _ site: ViewForEachSite,
        in source: String,
        bindingScopes: [ActiveBindingScope]
    ) async throws -> ViewForEachSourceReplacement {
        let activeOptionalBindings = activeBindings(at: site.startUTF8Offset, in: bindingScopes)
        let activeForEachBindings = activeForEachBindings(at: site.startUTF8Offset, in: bindingScopes)
        let collection = try await evaluateViewExpression(
            site.collectionExpression,
            fallback: "[]",
            activeBindings: activeOptionalBindings,
            forEachBindings: activeForEachBindings
        )
        let elements = try forEachElements(from: collection)
        let idPath = site.idKeyPath.flatMap(viewForEachSourceEditor.keyPathComponents)
        var seenIdentifiers = Set<RuntimeForEachID>()
        var expandedElements: [ViewForEachExpandedElement] = []
        expandedElements.reserveCapacity(elements.count)

        for element in elements {
            let itemBinding = RuntimeForEachItemBinding(name: site.itemName, value: element)
            let idExpression: String
            if let idPath {
                idExpression = idPath.reduce(site.itemName) { partial, component in
                    component == "self" ? partial : "\(partial).\(component)"
                }
            } else {
                idExpression = "\(site.itemName).id"
            }
            let idValue = try await evaluateViewExpression(
                idExpression,
                fallback: "nil",
                activeBindings: activeOptionalBindings,
                forEachBindings: activeForEachBindings + [itemBinding]
            )
            let identifier = try stableForEachIdentifier(idValue)
            guard seenIdentifiers.insert(identifier).inserted else {
                throw RuntimeViewLoweringError.duplicateForEachIdentifier(identifier.rawValue)
            }
            expandedElements.append(ViewForEachExpandedElement(
                id: identifier,
                binding: itemBinding,
                bodySource: site.bodySource
            ))
        }

        return try viewForEachSourceEditor.replacing(site, in: source, with: expandedElements)
    }

    private func forEachElements(from value: Value) throws -> [Value] {
        let elements: [Value]
        switch value {
        case .array(let array):
            elements = array
        case .set(let set):
            elements = set
        case .range(let lower, let upper, let closed):
            guard lower <= upper else {
                throw RuntimeViewLoweringError.unsupportedForEach(
                    "the evaluated range has an upper bound below its lower bound"
                )
            }
            let distance = upper.subtractingReportingOverflow(lower)
            guard !distance.overflow else {
                throw RuntimeViewLoweringError.unsupportedForEach("the evaluated range is too large")
            }
            let countResult: (partialValue: Int, overflow: Bool) = closed
                ? distance.partialValue.addingReportingOverflow(1)
                : (distance.partialValue, false)
            guard !countResult.overflow,
                  countResult.partialValue >= 0,
                  countResult.partialValue <= 10_000 else {
                throw RuntimeViewLoweringError.unsupportedForEach(
                    "collections are limited to 10,000 rows per view snapshot"
                )
            }
            elements = (0..<countResult.partialValue).map { offset in
                .int(lower + offset)
            }
        default:
            throw RuntimeViewLoweringError.unsupportedForEach(
                "expected an Array, Set, or integer range; got \(runtimeTypeName(of: value))"
            )
        }

        guard elements.count <= 10_000 else {
            throw RuntimeViewLoweringError.unsupportedForEach(
                "collections are limited to 10,000 rows per view snapshot"
            )
        }
        return elements
    }

    private func stableForEachIdentifier(_ value: Value) throws -> RuntimeForEachID {
        RuntimeForEachID(rawValue: try stableIdentifierComponent(value))
    }

    private func stableIdentifierComponent(_ value: Value) throws -> String {
        switch value {
        case .int(let number):
            return encodedIdentifier(tag: "Int", payload: String(number))
        case .double(let number):
            guard number.isFinite else {
                throw RuntimeViewLoweringError.unstableForEachIdentifier("Double")
            }
            let bits = number == 0 ? 0 : number.bitPattern
            return encodedIdentifier(tag: "Double", payload: String(bits, radix: 16))
        case .string(let string):
            return encodedIdentifier(tag: "String", payload: string)
        case .bool(let boolean):
            return encodedIdentifier(tag: "Bool", payload: String(boolean))
        case .optional(let wrapped):
            let payload: String
            if let wrapped {
                payload = try stableIdentifierComponent(wrapped)
            } else {
                payload = "nil"
            }
            return encodedIdentifier(
                tag: "Optional",
                payload: payload
            )
        case .tuple(let values, _):
            let parts = try values.map(stableIdentifierComponent).joined()
            return encodedIdentifier(tag: "Tuple[\(values.count)]", payload: parts)
        case .structValue(let typeName, let fields):
            let parts = try fields.map { field in
                encodedIdentifier(tag: field.name, payload: try stableIdentifierComponent(field.value))
            }.joined()
            return encodedIdentifier(tag: "Struct:\(typeName)", payload: parts)
        case .enumValue(let typeName, let caseName, let associatedValues):
            let payload = try associatedValues.map(stableIdentifierComponent).joined()
            return encodedIdentifier(
                tag: "Enum:\(typeName):\(caseName)[\(associatedValues.count)]",
                payload: payload
            )
        case .opaque(let typeName, let rawValue):
            let payload: String
            if let uuid = rawValue as? UUID {
                payload = uuid.uuidString
            } else if let string = rawValue as? String {
                payload = string
            } else if let url = rawValue as? URL {
                payload = url.absoluteString
            } else if let date = rawValue as? Date, date.timeIntervalSince1970.isFinite {
                payload = String(date.timeIntervalSince1970.bitPattern, radix: 16)
            } else if let data = rawValue as? Data {
                payload = data.base64EncodedString()
            } else {
                throw RuntimeViewLoweringError.unstableForEachIdentifier(typeName)
            }
            return encodedIdentifier(tag: "Opaque:\(typeName)", payload: payload)
        default:
            throw RuntimeViewLoweringError.unstableForEachIdentifier(runtimeTypeName(of: value))
        }
    }

    private func encodedIdentifier(tag: String, payload: String) -> String {
        "\(tag.utf8.count):\(tag)\(payload.utf8.count):\(payload)"
    }

    private func runtimeTypeName(of value: Value) -> String {
        switch value {
        case .int: return "Int"
        case .double: return "Double"
        case .string: return "String"
        case .bool: return "Bool"
        case .void: return "Void"
        case .function: return "Function"
        case .range: return "Range<Int>"
        case .array: return "Array"
        case .optional: return "Optional"
        case .tuple: return "Tuple"
        case .dict: return "Dictionary"
        case .set: return "Set"
        case .opaque(let typeName, _): return typeName
        case .structValue(let typeName, _): return typeName
        case .classInstance(let instance): return instance.typeName
        case .enumValue(let typeName, _, _): return typeName
        }
    }

    private func evaluateConditional(
        _ conditional: ViewConditionalSite,
        activeBindings: [ViewConditionalBinding],
        forEachBindings: [RuntimeForEachItemBinding]
    ) async throws -> Bool {
        let conditionExpression: String
        if let directExpression = conditional.conditionExpression,
           activeBindings.isEmpty,
           forEachBindings.isEmpty {
            conditionExpression = directExpression
        } else {
            conditionExpression = "if \(conditional.conditionSource) { true } else { false }"
        }
        let value = try await evaluateViewExpression(
            conditionExpression,
            fallback: "false",
            activeBindings: activeBindings,
            forEachBindings: forEachBindings
        )
        let displayValue = String(describing: value)
        guard displayValue == "true" || displayValue == "false" else {
            throw RuntimeViewLoweringError.unsupportedExpression(
                "conditional expression is not Bool: \(conditional.conditionSource)"
            )
        }
        return displayValue == "true"
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
            let values = try await shell.withCurrent { @Sendable in
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
            let values = try await shell.withCurrent { @Sendable in
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
            let activeForEachBindings = activeForEachBindings(at: site.utf8Offset, in: bindingScopes)
            let key = ScopedExpressionKey(
                expression: site.expression,
                bindings: activeBindings,
                forEachBindings: activeForEachBindings
            )
            if let cachedValue = cache[key] {
                values[site.utf8Offset] = cachedValue
                continue
            }
            let value = try await evaluateViewExpression(
                site.expression,
                fallback: "false",
                activeBindings: activeBindings,
                forEachBindings: activeForEachBindings
            )
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
            let activeForEachBindings = activeForEachBindings(at: site.utf8Offset, in: bindingScopes)
            let key = ScopedExpressionKey(
                expression: site.expression,
                bindings: activeBindings,
                forEachBindings: activeForEachBindings
            )
            if let cachedValue = cache[key] {
                values[site.utf8Offset] = cachedValue
                continue
            }
            let value = try await evaluateViewExpression(
                site.expression,
                fallback: "\"\"",
                activeBindings: activeBindings,
                forEachBindings: activeForEachBindings
            )
            let resolvedValue = String(describing: value)
            cache[key] = resolvedValue
            values[site.utf8Offset] = resolvedValue
        }
        return values
    }

    private func evaluateAction(_ action: RuntimeActionRegistration) async throws -> EvaluationResult {
        for (index, binding) in action.forEachBindings.enumerated() {
            interpreter.rootScope.bind(
                forEachTemporaryName(index),
                value: binding.value,
                mutable: false
            )
        }
        defer { clearForEachTemporaryBindings(count: action.forEachBindings.count) }

        let actionBody = action.forEachBindings.enumerated().reversed().reduce(action.source) {
            nestedSource, element in
            "({ \(element.element.name) in\n\(nestedSource)\n})(\(forEachTemporaryName(element.offset)))"
        }
        return try await evaluateLocked(actionBody, resetInterpreter: false)
    }

    /// Evaluates an expression as if it were inside the active view-builder
    /// lexical scopes. Iteration values are temporarily bound in a private
    /// namespace, then passed through ordinary interpreter closures so names
    /// in user source keep their normal lexical meaning.
    private func evaluateViewExpression(
        _ expression: String,
        fallback: String,
        activeBindings: [ViewConditionalBinding],
        forEachBindings: [RuntimeForEachItemBinding]
    ) async throws -> Value {
        for (index, binding) in forEachBindings.enumerated() {
            interpreter.rootScope.bind(
                forEachTemporaryName(index),
                value: binding.value,
                mutable: false
            )
        }
        defer { clearForEachTemporaryBindings(count: forEachBindings.count) }

        let expressionWithItems = forEachBindings.enumerated().reversed().reduce(expression) {
            nestedExpression, element in
            "({ \(element.element.name) in \(nestedExpression) })(\(forEachTemporaryName(element.offset)))"
        }
        let scopedExpression = expressionWithOptionalBindings(
            expressionWithItems,
            fallback: fallback,
            activeBindings: activeBindings
        )
        return try await interpreter.eval(scopedExpression)
    }

    private func forEachTemporaryName(_ index: Int) -> String {
        "\(forEachTemporaryPrefix)\(index)"
    }

    private func clearForEachTemporaryBindings(count: Int) {
        for index in 0..<count {
            interpreter.rootScope.bind(forEachTemporaryName(index), value: .void, mutable: false)
        }
    }

    private func activeForEachBindings(
        at offset: Int,
        in scopes: [ActiveBindingScope]
    ) -> [RuntimeForEachItemBinding] {
        scopes
            .filter { offset >= $0.lowerBound && offset < $0.upperBound }
            .sorted { $0.lowerBound < $1.lowerBound }
            .flatMap(\.forEachBindings)
    }

    private func actionForEachBindings(
        in source: String,
        bindingScopes: [ActiveBindingScope]
    ) throws -> [Int: [RuntimeForEachItemBinding]] {
        try viewExpressionLowerer.buttonCallOffsets(in: source).reduce(into: [:]) { result, offset in
            let captures = bindingScopes
                .filter { offset >= $0.lowerBound && offset < $0.upperBound }
                .sorted { $0.lowerBound < $1.lowerBound }
                .flatMap { $0.forEachBindings + $0.capturedActionBindings }
            if !captures.isEmpty {
                result[offset] = captures
            }
        }
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
                    bindings: scope.bindings,
                    forEachBindings: scope.forEachBindings,
                    capturedActionBindings: scope.capturedActionBindings
                )
            }
            if scope.lowerBound <= range.lowerBound && scope.upperBound >= range.upperBound {
                return ActiveBindingScope(
                    lowerBound: scope.lowerBound,
                    upperBound: scope.upperBound + offsetDelta,
                    bindings: scope.bindings,
                    forEachBindings: scope.forEachBindings,
                    capturedActionBindings: scope.capturedActionBindings
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
            "if let \(binding.name)\(binding.typeAnnotation) = \(binding.initializer) { \(nestedExpression) } else { \(fallback) }"
        }
    }
}
