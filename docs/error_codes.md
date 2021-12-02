## Error codes

### General init related
- `SP000`: `Could not finish initialization`
- `SP001`: `Threshold needs to be defined`

### General gas/ execution related
- `SP010`: `Safe transaction failed as txhash state is success`

### General signature validation related
- `SP020`: `Signatures data too short`
- `SP021`: `Signatures data too long`
- `SP022`: `Signatures size not match`
- `SP023`: `Invalid owner provided`
- `SP024`: `Signature duplicated`
- `SP025`: `Invalid contract signature provided`

### General auth related
- `SP030`: `Only owners can approve a hash`
- `SP031`: `Method can only be called from this contract`

### Module management related
- `SP100`: `Modules have already been initialized`
- `SP101`: `Invalid module address provided`
- `SP102`: `Module has already been added`
- `SP103`: `Invalid prevModule, module pair provided`
- `SP104`: `Method can only be called from an enabled module`

### Owner management related
- `SP200`: `Owners have already been setup`
- `SP201`: `Threshold cannot exceed owner count`
- `SP202`: `Threshold needs to be greater than 0`
- `SP203`: `Invalid owner address provided`
- `SP204`: `Address is already an owner`
- `SP205`: `Invalid prevOwner, owner pair provided`

### batchTransfer
- `SP300`:`tos len must equal to values`
- `SP301`:`double spend`