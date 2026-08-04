# Selecting a subset

Generate only the methods a project calls or implements, without renaming
anything.

## Overview

The full schema is thousands of files, and most projects need a fraction of it.
`--method` names one RPC; `--methods-file` points at a manifest, which is what a
list long enough to need reasons wants:

```text
# The methods this build needs.
auth.sendCode
messages.sendMessage    # inline comments work too

# Layer 228 moved this into messages.*; older layers still carry it.
channels.createForumTopic
```

Either way the semantics are the same, and they are deliberately not "generate
these declarations":

- names resolve against the **full** schema before filtering, so every surviving
  declaration keeps exactly the Swift name a full run would give it, collision
  suffixes included — growing the selection later never renames anything;
- every type transitively reachable from a selected method's fields and result
  comes along, so the output always compiles;
- a name in no schema at all is an error, never a silent omission.

``MethodManifest/parse(_:)`` is the parser, so a build script can hand the
generator a path instead of assembling hundreds of flags.
``ResolvedSchema/selecting(methods:)`` performs the reduction.
