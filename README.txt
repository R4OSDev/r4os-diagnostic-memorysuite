MEMSUITE.R4X
=============

MEMSUITE prueft den aktuellen Speichervertrag ueber R4SYS und R4DEV:

- virtuelle Reserve, Commit, Decommit, Release und Query
- Programminstanz-Speicherprofil und Grenzen
- Memory-Pressure-, Reclaim- und OOM-Snapshots
- FS-Cache-Reclaim und PMM-Frame-Rueckgabe
- Backing-Store-, Slot-, Page-I/O- und VM-Page-State-Diagnose
- Fehlerklassifikation, Retry und Recovery

Seit 0.59.7 bleiben `ProgramStatus` und `ProgramInstanceInfo` fuer diese
Pruefungen unveraendert. Ihre Reserved-/Committed-/Resident- und Stackfelder
beschreiben weiter die Program-VM, nicht die neuen internen Heap-Payloads.
Kern-/Runtime-/Console-/GUI-Payloadgroessen, Peaks, Rollbacks und den
deterministischen Payload-Fehlertest prueft getrennt
`CLEANUPD /PROGRAMSTORAGE` ueber die optionalen R4DEV-v2-Funktionen.

/VMSTRESS fuehrt die VM-Stressabnahme aus, /STRICT die strenge Gesamtabnahme.
Optionale Diagnosefelder werden mit hasFn geprueft.
