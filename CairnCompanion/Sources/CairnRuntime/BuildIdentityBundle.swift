import CairnCore
import Foundation

public extension BuildIdentity {
    /// This build, as it stamped itself at compile time.
    ///
    /// `CairnChannel` and `CairnCommit` are written into the Info.plist from the `CAIRN_CHANNEL`
    /// and `CAIRN_COMMIT` build settings; `scripts/release-testflight.sh` passes the real values
    /// and the defaults in `project.yml` are `dev` and `unknown`, so a build made by hand reads
    /// as exactly that.
    static let current = BuildIdentity(infoDictionary: Bundle.main.infoDictionary)
}
