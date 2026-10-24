/// One source→target pair's language-pack state, as the app sees it. Free of
/// Translation-framework types: the framework enum never leaves the translator,
/// so this is the vocabulary the pipeline, the controller and Settings share.
public enum PackStatus: Equatable {
    case installed, downloadable, unsupported
}

/// What a translator answered for one batch — the reason matters: the
/// display-lines pipeline caches only deterministic outcomes.
public enum TranslateOutcome: Equatable {
    case translated([String])  // one text per requested line, in order
    case packNotDownloaded     // pair exists, pack not installed (Settings downloads it)
    case unsupported           // pair not offered on this macOS
    case failed                // framework error or deadline — transient
    case skipped               // the caller said the job no longer matters
}
