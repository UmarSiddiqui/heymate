# Publication source review — 2026-10-29

Status: unresolved, advisory. Current implementation must not be represented as cleared for publication.

The local drawing parameter work uses Swift-native paths. Separate drawing,
geometry, browser, notes, workflow and shader resources retain recovered source.
Renaming symbols, changing comments, and correcting spelling do not establish
independent authorship or permission to distribute those implementations.

`../publication-sources.json` records known unresolved files. The user requested release on 2026-10-29 with this review unresolved.
The release workflow and manual release script no longer enforce this inventory.
Local signed development builds remain available for comparison.
The advisory review is not legal clearance, and the inventory is
not a claim that every other file has already been reviewed.

No bulk replacement has been accepted. Preserve public command schemas,
streaming behavior, safety controls and rendering until reviewed replacements
pass regression and visual comparisons. Existing licensed dependencies retain
their notices; publishing requires completing the separate source review.

Original reference material and pre-rename snapshots were preserved outside
this checkout in the sibling `HeyMateReferenceArchive` directory. Historical
hashes remain in manifests beside hashes of the renamed local resources.
Current hashes validate packaging only; they do not prove originality.

Validation so far: 30 browser/render tests and 63 agent-runtime tests pass.
Four isolated publication-gate tests also pass; the actual inventory correctly
reports unresolved source review; release enforcement was subsequently removed by user request. Signed local installation passes certificate, mutually compatible designated
requirements, nested signature checks, and startup verification. These checks
provide regression evidence; they do not establish complete behavioral parity.

Known misspelled internal reference comments were replaced with neutral resource
descriptions. Source and resource names use this project's namespace. Source
history, generated build artifacts and the external reference archive are not
rewritten by this cleanup.
