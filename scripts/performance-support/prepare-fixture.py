"""Inject offline-only startup into a disposable source copy, failing closed."""
import json
import os
import pathlib
import sys

staging, repository = map(pathlib.Path, sys.argv[1:3])
workload = sys.argv[3]
assert workload in ("light", "heavy")
assert staging.resolve() != repository.resolve()


def replace_once(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise SystemExit(f"Fixture hook changed in {path.name}; inspect before profiling")
    path.write_text(source.replace(old, new))


# No normal startup, workspace lease, runtime discovery, account restoration,
# note socket, usage collection, or provider coordinator is started.
app = staging / "app/App/WovenMatterApp.swift"
replace_once(app, "workspaceProcessLease = isRunningUnitTests\n", "workspaceProcessLease = true\n")
replace_once(app, "_applicationModel = State(initialValue: ApplicationModel())", """
        precondition(Bundle.main.bundleIdentifier == "wovenmatter.desktop.dev.performance")
        let fixtureModel = ApplicationModel(startsAutomatically: false)
        _applicationModel = State(initialValue: fixtureModel)
        Task { await fixtureModel.startPerformanceFixture(heavy: %s || CommandLine.arguments.contains("--heavy")) }
""" % ("true" if workload == "heavy" else "false"))
replace_once(staging / "app/App/WovenMatterLifecycleDelegate.swift", """        model?.refreshRuntimeInventory()
        model?.refreshLocalACPRuntimesNow()
        model?.remoteWorkspaces.refreshRuntimeMaintenanceAtStartup()
""", "")
replace_once(app, "        .commands {\n", """        .commands {
            CommandMenu("Fixture") {
                Button("Run synthetic stream") {
                    Task { await applicationModel.runPerformanceFixtureStream() }
                }
            }
""")
model = staging / "app/App/ApplicationModel.swift"
evidence = pathlib.Path(os.environ.get(
    "WOVENMATTER_PERFORMANCE_EVIDENCE_DIR",
    str(repository / ".build/performance-evidence"),
)).resolve()
evidence.mkdir(parents=True, exist_ok=True)
with model.open("a") as output:
    output.write("\nprivate enum PerformanceFixtureEnvironment {\n"
                 "    static let evidenceDirectory = URL(fileURLWithPath: "
                 + json.dumps(str(evidence)) + ")\n}\n")
    output.write((repository / "scripts/performance-support/PerformanceFixture.swift").read_text())
