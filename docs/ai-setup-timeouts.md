# AI provider setup deadlines

The owner reported a request-time-limit error when connecting an NVIDIA key. Code review confirmed a25s model-list timeout and30s blocking chat-probe timeout. No live provider trace or owner's key was accessed, so network/provider queue/model latency remain hypotheses rather than a proven remote root cause.

Changes:
- Catalog request45s; chat connection probe120s. A task-group deadline enforces total time as well as URLSession's idle request timeout.
- Timeout maps to a specific catalog/probe message, distinct from rejected key,429rate limits,server errors and cancellation. No paid retry or alternative-model loop.
- Existing provider/key/model remain intact unless the probe succeeds and account/configuration revisions still match. Cancel aborts the operation and does not commit staged credentials.
- Automatic candidate ranking uses catalog-reported IDs only. Small parameter-count/non-reasoning names are latency hints; no access/speed guarantee. Existing available selection is preserved; explicit model choices are never replaced.
- Settings show wait/progress and Stop. Dify remains a blocking probe with server-managed model; its chat/session state is not changed by a health request.

Offline native fixtures verify timeout mapping,45/120s request properties, cancellation and preservation,one paid attempt only,small automatic candidate preference and explicit-current preservation. They do not verify real model responsiveness or a particular API key. iOS SDK concurrency/build is checked by Build IPA.

Administrator-only settings require an explicit approved account identity. The repository currently has no administrator role or owner allowlist. Do not grant admin status to any logged-in user,first login,first installation or device-local toggle; obtain the owner's intended Yandex account/UID before activating a role gate. Native UI hiding is not backend authorization and cannot make embedded shared API keys safe.
