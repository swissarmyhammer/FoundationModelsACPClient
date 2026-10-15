---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: 'New warning: ServiceContext is deprecated in swift-distributed-tracing 1.7 (6 warnings in Sources)'
---
Found in T0. `swift package update` resolves swift-distributed-tracing 1.7.1. Since 1.7.0, `ServiceContext` is a deprecated typealias of `InstrumentationContext`. `swift build` gives 6 deprecation warnings: `Telemetry/TracedClientMessage.swift:84`, `Telemetry/ClientRequestSpan.swift:140, 146, 238, 245`, `Telemetry/AgentRequestSpan.swift:101`. The manifest floor is `from: "1.4.1"`, and `InstrumentationContext` does not exist before 1.6.0.

Not in the plan. Decision needed from the step owner:
A. Rename to `InstrumentationContext` and raise the floor to 1.7.0 (the floor of FoundationModelsExtras must then allow it).
B. Keep the code as it is in step 6, and leave this task open.

Also seen (not new): `warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle` in all three graphs (see done task ^zws9qzt, which has no checked box). #mail-step-6