# Airtable Import — Backlog

Items that were skipped or degraded during the Airtable import
(log of the base with tables `Students & Alumni`, `Placements`, etc.).

## Formula fields (skipped: "column type not supported yet")

Pure formula fields are not converted. Only `CREATED_TIME()` and
`LAST_MODIFIED_TIME()` are mapped (to DateTime). With the import option
"Import formula" enabled, formulas are created as empty placeholders
(`""`) and the original Airtable formula is stored in the column description.

| Table | Field |
| --- | --- |
| Placements | Employer, Contact, Address, & Ph_ # |
| Placements | AFU Added Date |
| Placements | Before BPPE Date? |
| Placements | Before ACCSC Date? |
| Placements | Paid? |
| Placements | Student Name |
| Placements | Documentation Status |
| Weeklies Log | Contact Summary |
| Comms Log | 📅 Contact or Topic |
| Dept SOPs | Goal ID |
| Dept SOPs | Time Status Changed |
| EPD Lab Assignments | Available Lab Capacity |
| Forms - Data | Name |
| Forms - Data | Student Full Address |
| Forms - Data | Company Full Address |
| Registrar Import | Preferred Name |
| Registrar Import | CDIV Convert |
| Registrar Import | Program Convert |
| Registrar Import | INTL Convert |
| BPPE Annual Report | Grad Cohort |
| BPPE Annual Report | Program Name |
| BPPE Annual Report | Institution Rep Name and Title |
| ACCSC Annual Report | Cohort |
| Employers and Industries \| 👤💼 | Record ID |
| Auxicent | Program |
| Meetings Log | Meeting Attended |
| ACCSC Placement Rates (%) | Placement Rate - DP |
| ACCSC Placement Rates (%) | Placement Rate - BFA |
| ACCSC Placement Rates (%) | Placement Rate - EDDP |
| ACCSC Placement Rates (%) | DP Uncategorized |
| ACCSC Placement Rates (%) | BFA Uncategorized |
| ACCSC Placement Rates (%) | # DP Placements needed to reach target |
| ACCSC Placement Rates (%) | # BFA Placements needed to reach target |
| ACCSC Placement Rates (%) | BFA Target Status |
| ACCSC Placement Rates (%) | DP Target Status |
| BPPE Placement Rates (%) | Placement Rate - DP |
| BPPE Placement Rates (%) | Placement Rate - BFA |
| Emails and Communications | Comma Separated List |

Total: 39 formula fields.

## Select options

- `Class Division` — duplicate option `Term 1`. NocoDB does not allow duplicate
  option titles, the second one is dropped; records using it map to the first.

## Other unsupported field types (not hit in this base, but skipped by the importer)

- Button fields (`button`) — always skipped.
- Rollups that reference an unsupported column type — skipped.

## Fixed

- Import failed on SQLite with `duplicate column name: Created_By` because the
  Airtable field `Created By` clashed case-insensitively with the system column
  `created_by`. Column-name deduplication in `tableCreate` is now case-insensitive,
  so the field is created as `Created_By_1` (the field title stays `Created By`).
