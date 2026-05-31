import AutocompleteCore

public struct CompletionPolicy: Equatable {
    public var isCompletionEnabled: Bool
    public var allowsMidLineCompletion: Bool
    public var allowsTabAcceptance: Bool
    public var allowsTrainingDataCollection: Bool
    public var insertionRequiresPasteAndMatchStyle: Bool
    public var insertionRequiresNonBreakingSpace: Bool
    public var stringInjectionChunkSize: Int?
    public var insertionRequiresBackspaceAfterPaste: Bool
    public var fontSizeAdjustmentFactor: Double
    public var verticalAlignmentOffset: Double
    public var overlayPreference: OverlayPreference
    public var completionMode: CompletionMode
    public var customInstructions: [String]
    /// Whether app/window/field metadata is included in the prompt. False for code editors and
    /// terminals (see `TargetOverride.environmentContextDisabled` / ADR-017).
    public var includesEnvironmentContext: Bool
    public var excludesSecureField: Bool

    public init(
        isCompletionEnabled: Bool = true,
        allowsMidLineCompletion: Bool = true,
        allowsTabAcceptance: Bool = true,
        allowsTrainingDataCollection: Bool = true,
        insertionRequiresPasteAndMatchStyle: Bool = false,
        insertionRequiresNonBreakingSpace: Bool = false,
        stringInjectionChunkSize: Int? = nil,
        insertionRequiresBackspaceAfterPaste: Bool = false,
        fontSizeAdjustmentFactor: Double = 1,
        verticalAlignmentOffset: Double = 0,
        overlayPreference: OverlayPreference = .inline,
        completionMode: CompletionMode = .prose,
        customInstructions: [String] = [],
        includesEnvironmentContext: Bool = true,
        excludesSecureField: Bool = false
    ) {
        self.isCompletionEnabled = isCompletionEnabled
        self.allowsMidLineCompletion = allowsMidLineCompletion
        self.allowsTabAcceptance = allowsTabAcceptance
        self.allowsTrainingDataCollection = allowsTrainingDataCollection
        self.insertionRequiresPasteAndMatchStyle = insertionRequiresPasteAndMatchStyle
        self.insertionRequiresNonBreakingSpace = insertionRequiresNonBreakingSpace
        self.stringInjectionChunkSize = stringInjectionChunkSize
        self.insertionRequiresBackspaceAfterPaste = insertionRequiresBackspaceAfterPaste
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
        self.verticalAlignmentOffset = verticalAlignmentOffset
        self.overlayPreference = overlayPreference
        self.completionMode = completionMode
        self.customInstructions = customInstructions
        self.includesEnvironmentContext = includesEnvironmentContext
        self.excludesSecureField = excludesSecureField
    }
}
