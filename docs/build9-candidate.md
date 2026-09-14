# Build 9 — design gallery round 2

Build identity `0.1 (9)`.

Updates the developer-only in-app design gallery with **Midnight Original**, **Midnight Contrast**, and **Adaptive Preview**, while retaining round-1 references. Midnight Contrast preserves the original deep background and modestly raises card/border hierarchy. Adaptive Preview is gallery-only with explicit Dark/Light inspection; production styling remains unchanged.

Independent review found no P0/P1 blocker and accepted installation for exploration. Two P2 evidence notes remain: the contrast script does not model every alpha-composited rendered text pair, and Adaptive Preview dark reference screenshots are not committed because its dark palette equals Midnight Original; it remains directly selectable on-device. These notes preclude treating the gallery as final production styling evidence.

Exact merged-tree validation: 84 root tests passed and the signed generic-device build succeeded with bundle version 9. Build 9 was installed and launched successfully on the paired iPhone on 2026-09-14 at 00:15 local.
