import FoundationModelsExtras
import Testing

/// A component that reports one finding of its own, so ``DoctorRunner`` has
/// something to gather.
///
/// This type *conforms to* `Doctorable` instead of only naming it, which is the
/// stronger proof of the two: a protocol the dependency does not carry cannot
/// be conformed to.
private struct StubDoctorComponent: Doctorable {
    /// What the one finding of this component says.
    static let message = "the Doctor module resolves"

    /// What this component is called in the doctor report.
    let doctorName = "the resolved Doctor module"

    /// Which group the finding of this component belongs to.
    let doctorCategory = "dependencies"

    /// Reports the one finding this component owns.
    ///
    /// - Returns: A single passing finding, named after this component.
    func runHealthChecks() async -> [HealthCheck] {
        [.ok(name: doctorName, message: Self.message, category: doctorCategory)]
    }
}

/// Proves the `Doctor` module of `FoundationModelsExtras` is reachable from
/// this package, and so guards the dependency revision that carries it.
///
/// **Why this file exists.** The Doctor types landed in
/// `FoundationModelsExtras` before they were published, so this package
/// resolved a revision that held none of them and every `doctor` task failed
/// to compile. `.gitignore` names `Package.resolved`, so no diff ever shows
/// the pin moving back. This file is the guard instead: it names each of the
/// six types the `doctor` subcommand stands on — `Doctorable`,
/// `DoctorRunner`, `DoctorReport`, `HealthCheck`, `HealthStatus` and
/// `PlainTextDoctorRenderer` — in an explicit type annotation, so the file
/// cannot compile against a revision that lacks any one of them.
///
/// Each test also asserts a behaviour the `doctor` subcommand depends on, so
/// a passing run reports more than "the names resolve".
@Suite("Extras Doctor reachability")
struct ExtrasDoctorReachableTests {
    /// What the findings this suite builds say they checked.
    private static let checkName = "the agent command"

    /// What the findings this suite builds report.
    private static let checkMessage = "the command names no executable"

    /// The action the failing findings of this suite carry.
    private static let checkFix = "give --agent an executable on PATH"

    /// The group the findings of this suite belong to.
    private static let checkCategory = "configuration"

    /// A report that holds nothing is passing: the runner checked nothing, so
    /// nothing is wrong. The `doctor` subcommand reads this to exit zero when
    /// every component is turned off.
    @Test("an empty report is ok")
    func anEmptyReportIsOk() {
        let noChecks: [HealthCheck] = []
        let report: DoctorReport = DoctorReport(checks: noChecks)
        #expect(report.worstStatus == HealthStatus.ok)
    }

    /// The `doctor` subcommand ranks the findings of every component to pick
    /// one exit code, so the ranking is the behaviour it stands on. This names
    /// all three cases of `HealthStatus` and pins the order between them.
    @Test("an error outranks a warning, and a warning outranks ok")
    func anErrorOutranksAWarningAndAWarningOutranksOk() {
        let passing: HealthStatus = .ok
        let attention: HealthStatus = .warning
        let broken: HealthStatus = .error
        #expect(DoctorReport(checks: [Self.makeCheck(reporting: passing)]).worstStatus == passing)
        #expect(
            DoctorReport(checks: [Self.makeCheck(reporting: passing), Self.makeCheck(reporting: attention)])
                .worstStatus == attention,
            "a warning beside a passing finding must be the worst of the two")
        #expect(
            DoctorReport(checks: [Self.makeCheck(reporting: attention), Self.makeCheck(reporting: broken)])
                .worstStatus == broken,
            "an error beside a warning must be the worst of the two")
    }

    /// The doctor tasks build their failing findings through this factory, and
    /// they rely on it requiring a fix. This pins the argument labels and the
    /// status the factory writes.
    @Test("the error factory keeps the fix it was given")
    func theErrorFactoryKeepsTheFixItWasGiven() {
        let check: HealthCheck = .error(
            name: Self.checkName,
            message: Self.checkMessage,
            fix: Self.checkFix,
            category: Self.checkCategory)
        #expect(check.status == HealthStatus.error)
        #expect(check.fix == Self.checkFix, "the error factory must carry its fix onto the finding")
        #expect(check.name == Self.checkName)
        #expect(check.category == Self.checkCategory)
    }

    /// The `doctor` subcommand registers its components with the runner and
    /// reads back one report. This proves a component of this package can
    /// conform to `Doctorable` and that the runner gathers what it reports.
    @Test("the runner gathers the finding of a registered component")
    func theRunnerGathersTheFindingOfARegisteredComponent() async {
        let component: any Doctorable = StubDoctorComponent()
        let runner: DoctorRunner = DoctorRunner(components: [component])
        let report = await runner.run()
        #expect(
            report.checks == [
                HealthCheck(
                    name: component.doctorName,
                    status: .ok,
                    message: StubDoctorComponent.message,
                    fix: nil,
                    category: component.doctorCategory)
            ])
    }

    /// The `doctor` subcommand draws its report with this renderer. This pins
    /// that a rendering carries both halves of a failing finding — what broke,
    /// and what repairs it.
    @Test("the plain text renderer draws the name and the fix of a finding")
    func thePlainTextRendererDrawsTheNameAndTheFixOfAFinding() {
        let renderer: PlainTextDoctorRenderer = PlainTextDoctorRenderer()
        let rendering = renderer.render(
            DoctorReport(checks: [Self.makeCheck(reporting: .error)]))
        #expect(rendering.contains(Self.checkName), "the rendering must name what was checked")
        #expect(rendering.contains(Self.checkFix), "the rendering must carry the fix of a broken finding")
    }

    /// Builds one finding reporting the given status, so a test can state a
    /// ranking without repeating the four strings each finding carries.
    ///
    /// - Parameter status: How the finding is to report.
    /// - Returns: A finding over the strings this suite names, carrying a fix
    ///   for every status other than ``HealthStatus/ok``.
    private static func makeCheck(reporting status: HealthStatus) -> HealthCheck {
        switch status {
        case .ok: .ok(name: checkName, message: checkMessage, category: checkCategory)
        case .warning:
            .warning(name: checkName, message: checkMessage, fix: checkFix, category: checkCategory)
        case .error:
            .error(name: checkName, message: checkMessage, fix: checkFix, category: checkCategory)
        }
    }
}
